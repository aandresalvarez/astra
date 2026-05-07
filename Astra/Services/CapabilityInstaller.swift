import Foundation
import SwiftData
import ASTRACore

@MainActor
struct CapabilityInstaller {
    enum InstallationError: Error, Equatable, LocalizedError {
        case blocked([String])

        var errorDescription: String? {
            switch self {
            case .blocked(let messages):
                return messages.joined(separator: "\n")
            }
        }
    }

    struct InstallationResult: Equatable {
        var packageID: String
        var skillIDs: [UUID]
        var connectorIDs: [UUID]
        var localToolIDs: [UUID]
        var templateIDs: [UUID]
    }

    let library: CapabilityLibrary
    let appVersion: SemanticVersion

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
    ) {
        self.library = library
        self.appVersion = appVersion
    }

    @discardableResult
    func install(
        _ package: PluginPackage,
        into workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:]
    ) throws -> InstallationResult {
        let blockers = installBlockerMessages(for: package, in: workspace)
        guard blockers.isEmpty else {
            throw InstallationError.blocked(blockers)
        }
        try library.install(package)
        let result = enable(
            package,
            in: workspace,
            modelContext: modelContext,
            credentialInputs: credentialInputs,
            configInputs: configInputs,
            baseURLOverrides: baseURLOverrides
        )
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
            "package_id": package.id,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString
        ])
        return result
    }

    @discardableResult
    func enable(
        _ package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:]
    ) -> InstallationResult {
        var skillIDs: [UUID] = []
        var connectorIDs: [UUID] = []
        var localToolIDs: [UUID] = []
        var templateIDs: [UUID] = []
        var skillsByName: [String: Skill] = [:]

        let skillConfigInputs = package.connectors.isEmpty ? configInputs : [:]
        let packageEnvironmentKeys = package.skills.flatMap(\.environmentKeys)

        for pluginSkill in package.skills {
            let skill = upsertGlobalSkill(
                pluginSkill,
                modelContext: modelContext,
                configInputs: skillConfigInputs
            )
            skillsByName[pluginSkill.name] = skill
            appendUnique(skill.id.uuidString, to: &workspace.enabledGlobalSkillIDs)
            appendUnique(skill.id, to: &skillIDs)
        }

        let primarySkill = package.skills.first.flatMap { skillsByName[$0.name] }

        for pluginConnector in package.connectors {
            let configKeys = connectorConfigKeys(
                hints: pluginConnector.configHints,
                extraConfigKeys: packageEnvironmentKeys,
                configInputs: configInputs
            )
            let baseURL = baseURLOverrides[pluginConnector.name] ?? pluginConnector.baseURL
            let connector: Connector
            if connectorHasScopedInputs(
                pluginConnector,
                configKeys: configKeys,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverridden: baseURLOverrides[pluginConnector.name] != nil
            ) {
                connector = upsertWorkspaceConnector(
                    pluginConnector,
                    workspace: workspace,
                    modelContext: modelContext,
                    credentialInputs: credentialInputs,
                    configInputs: configInputs,
                    extraConfigKeys: packageEnvironmentKeys,
                    baseURL: baseURL
                )
                removeMatchingGlobalConnectorActivation(
                    pluginConnector,
                    from: workspace,
                    modelContext: modelContext
                )
            } else {
                connector = upsertGlobalConnector(
                    pluginConnector,
                    modelContext: modelContext,
                    credentialInputs: credentialInputs,
                    configInputs: configInputs,
                    extraConfigKeys: packageEnvironmentKeys,
                    baseURL: baseURL
                )
                if let primarySkill, connector.skill == nil {
                    connector.skill = primarySkill
                }
                appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
            }
            appendUnique(connector.id, to: &connectorIDs)
        }

        for pluginTool in package.localTools {
            let tool = upsertGlobalTool(pluginTool, modelContext: modelContext)
            if let primarySkill, tool.skill == nil {
                tool.skill = primarySkill
            }
            if primarySkill == nil {
                appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
            }
            appendUnique(tool.id, to: &localToolIDs)
        }

        for pluginTemplate in package.templates {
            let template = upsertWorkspaceTemplate(pluginTemplate, workspace: workspace, modelContext: modelContext)
            appendUnique(template.id, to: &templateIDs)
        }

        appendUnique(package.id, to: &workspace.enabledCapabilityIDs)
        workspace.recordInstalledPlugin(id: package.id, version: package.version)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
            "package_id": package.id,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(skillIDs.count),
            "connectors_count": String(connectorIDs.count),
            "tools_count": String(localToolIDs.count)
        ])

        return InstallationResult(
            packageID: package.id,
            skillIDs: skillIDs,
            connectorIDs: connectorIDs,
            localToolIDs: localToolIDs,
            templateIDs: templateIDs
        )
    }

    private func upsertGlobalSkill(
        _ pluginSkill: PluginSkill,
        modelContext: ModelContext,
        configInputs: [String: String]
    ) -> Skill {
        let skill = existingGlobalSkill(named: pluginSkill.name, modelContext: modelContext) ?? Skill(
            name: pluginSkill.name,
            icon: pluginSkill.icon,
            skillDescription: pluginSkill.description,
            allowedTools: pluginSkill.allowedTools,
            disallowedTools: pluginSkill.disallowedTools,
            customTools: pluginSkill.customTools,
            behaviorInstructions: pluginSkill.behaviorInstructions
        )
        if skill.modelContext == nil {
            modelContext.insert(skill)
        }
        skill.name = pluginSkill.name
        skill.icon = pluginSkill.icon
        skill.skillDescription = pluginSkill.description
        skill.allowedTools = pluginSkill.allowedTools
        skill.disallowedTools = pluginSkill.disallowedTools
        skill.customTools = pluginSkill.customTools
        skill.behaviorInstructions = pluginSkill.behaviorInstructions
        skill.environmentKeys = pluginSkill.environmentKeys
        skill.environmentValues = environmentValues(for: pluginSkill, configInputs: configInputs)
        skill.isGlobal = true
        skill.workspace = nil
        skill.updatedAt = Date()
        skill.migrateSecretsToKeychain()
        return skill
    }

    private func environmentValues(
        for pluginSkill: PluginSkill,
        configInputs: [String: String]
    ) -> [String] {
        pluginSkill.environmentKeys.enumerated().map { index, key in
            if let configured = configInputs[key] {
                return configured
            }
            guard index < pluginSkill.environmentValues.count else { return "" }
            return pluginSkill.environmentValues[index]
        }
    }

    private func upsertGlobalConnector(
        _ pluginConnector: PluginConnector,
        modelContext: ModelContext,
        credentialInputs: [String: String],
        configInputs: [String: String],
        extraConfigKeys: [String],
        baseURL: String
    ) -> Connector {
        let connector = existingGlobalConnector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            baseURL: baseURL,
            modelContext: modelContext
        ) ?? Connector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            icon: pluginConnector.icon,
            connectorDescription: pluginConnector.description,
            baseURL: baseURL,
            authMethod: pluginConnector.authMethod
        )
        if connector.modelContext == nil {
            modelContext.insert(connector)
        }
        connector.name = pluginConnector.name
        connector.serviceType = pluginConnector.serviceType
        connector.icon = pluginConnector.icon
        connector.connectorDescription = pluginConnector.description
        connector.baseURL = baseURL
        connector.authMethod = pluginConnector.authMethod
        connector.notes = pluginConnector.notes
        connector.credentialKeys = pluginConnector.credentialHints.map(\.key)
        connector.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
        connector.configKeys = connectorConfigKeys(
            hints: pluginConnector.configHints,
            extraConfigKeys: extraConfigKeys,
            configInputs: configInputs
        )
        connector.configValues = connector.configKeys.map { configInputs[$0] ?? "" }
        connector.isGlobal = true
        connector.workspace = nil
        connector.updatedAt = Date()
        if connector.isStanfordOutlookMail {
            connector.applyStanfordOutlookDefaults()
        }
        for hint in pluginConnector.credentialHints {
            if let value = credentialInputs[hint.key], !value.isEmpty {
                connector.saveCredential(key: hint.key, value: value)
            }
        }
        return connector
    }

    private func upsertWorkspaceConnector(
        _ pluginConnector: PluginConnector,
        workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String],
        configInputs: [String: String],
        extraConfigKeys: [String],
        baseURL: String
    ) -> Connector {
        let connector = existingWorkspaceConnector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            workspace: workspace
        ) ?? Connector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            icon: pluginConnector.icon,
            connectorDescription: pluginConnector.description,
            baseURL: baseURL,
            authMethod: pluginConnector.authMethod
        )
        if connector.modelContext == nil {
            modelContext.insert(connector)
        }
        connector.name = pluginConnector.name
        connector.serviceType = pluginConnector.serviceType
        connector.icon = pluginConnector.icon
        connector.connectorDescription = pluginConnector.description
        connector.baseURL = baseURL
        connector.authMethod = pluginConnector.authMethod
        connector.notes = pluginConnector.notes
        connector.credentialKeys = pluginConnector.credentialHints.map(\.key)
        connector.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
        connector.configKeys = connectorConfigKeys(
            hints: pluginConnector.configHints,
            extraConfigKeys: extraConfigKeys,
            configInputs: configInputs
        )
        connector.configValues = connector.configKeys.map { configInputs[$0] ?? "" }
        connector.isGlobal = false
        connector.workspace = workspace
        connector.skill = nil
        connector.updatedAt = Date()
        if connector.isStanfordOutlookMail {
            connector.applyStanfordOutlookDefaults()
        }
        for hint in pluginConnector.credentialHints {
            if let value = credentialInputs[hint.key], !value.isEmpty {
                connector.saveCredential(key: hint.key, value: value)
            }
        }
        return connector
    }

    private func connectorConfigKeys(
        hints: [PluginConnector.ConfigHint],
        extraConfigKeys: [String],
        configInputs: [String: String]
    ) -> [String] {
        var keys = hints.map(\.key)
        for key in extraConfigKeys where configInputs[key] != nil && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func connectorHasScopedInputs(
        _ pluginConnector: PluginConnector,
        configKeys: [String],
        credentialInputs: [String: String],
        configInputs: [String: String],
        baseURLOverridden: Bool
    ) -> Bool {
        if baseURLOverridden {
            return true
        }
        if pluginConnector.credentialHints.contains(where: { hint in
            !(credentialInputs[hint.key] ?? "").isEmpty
        }) {
            return true
        }
        return configKeys.contains { key in
            !(configInputs[key] ?? "").isEmpty
        }
    }

    private func removeMatchingGlobalConnectorActivation(
        _ pluginConnector: PluginConnector,
        from workspace: Workspace,
        modelContext: ModelContext
    ) {
        guard !workspace.enabledGlobalConnectorIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
        guard let globalConnectors = try? modelContext.fetch(descriptor) else { return }
        let matchingIDs = Set(
            globalConnectors
                .filter {
                    $0.name == pluginConnector.name &&
                    $0.serviceType == pluginConnector.serviceType
                }
                .map { $0.id.uuidString }
        )
        guard !matchingIDs.isEmpty else { return }
        workspace.enabledGlobalConnectorIDs.removeAll { matchingIDs.contains($0) }
    }

    private func upsertGlobalTool(_ pluginTool: PluginLocalTool, modelContext: ModelContext) -> LocalTool {
        let tool = existingGlobalTool(
            name: pluginTool.name,
            toolType: pluginTool.toolType,
            command: pluginTool.command,
            modelContext: modelContext
        ) ?? LocalTool(
            name: pluginTool.name,
            toolDescription: pluginTool.description,
            icon: pluginTool.icon,
            toolType: pluginTool.toolType,
            command: pluginTool.command,
            arguments: pluginTool.arguments
        )
        if tool.modelContext == nil {
            modelContext.insert(tool)
        }
        tool.name = pluginTool.name
        tool.toolDescription = pluginTool.description
        tool.icon = pluginTool.icon
        tool.toolType = pluginTool.toolType
        tool.command = pluginTool.command
        tool.arguments = pluginTool.arguments
        tool.isGlobal = true
        tool.workspace = nil
        tool.updatedAt = Date()
        return tool
    }

    private func upsertWorkspaceTemplate(
        _ pluginTemplate: PluginTemplate,
        workspace: Workspace,
        modelContext: ModelContext
    ) -> TaskTemplate {
        let template = workspace.templates.first { $0.name == pluginTemplate.name } ?? TaskTemplate(
            name: pluginTemplate.name,
            mainGoal: pluginTemplate.mainGoal,
            workspace: workspace,
            icon: pluginTemplate.icon,
            templateDescription: pluginTemplate.description
        )
        if template.modelContext == nil {
            modelContext.insert(template)
        }
        template.icon = pluginTemplate.icon
        template.templateDescription = pluginTemplate.description
        template.mainGoal = pluginTemplate.mainGoal
        template.beforeGoal = pluginTemplate.beforeGoal
        template.afterGoal = pluginTemplate.afterGoal
        template.mainBudget = pluginTemplate.mainBudget
        template.beforeBudget = pluginTemplate.beforeBudget
        template.afterBudget = pluginTemplate.afterBudget
        template.variablesJSON = pluginTemplate.variablesJSON
        template.passContextToMain = pluginTemplate.passContextToMain
        template.passContextToAfter = pluginTemplate.passContextToAfter
        template.updatedAt = Date()
        return template
    }

    private func existingGlobalSkill(named name: String, modelContext: ModelContext) -> Skill? {
        let descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate {
                $0.name == name &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func existingGlobalConnector(
        name: String,
        serviceType: String,
        baseURL: String,
        modelContext: ModelContext
    ) -> Connector? {
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

    private func existingWorkspaceConnector(
        name: String,
        serviceType: String,
        workspace: Workspace
    ) -> Connector? {
        workspace.connectors.first {
            $0.name == name && $0.serviceType == serviceType
        }
    }

    private func existingGlobalTool(
        name: String,
        toolType: String,
        command: String,
        modelContext: ModelContext
    ) -> LocalTool? {
        let descriptor = FetchDescriptor<LocalTool>(
            predicate: #Predicate {
                $0.name == name &&
                $0.toolType == toolType &&
                $0.command == command &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private func appendUnique(_ value: UUID, to values: inout [UUID]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private func installBlockerMessages(for package: PluginPackage, in workspace: Workspace) -> [String] {
        package.installBlockers(
            appVersion: appVersion,
            installedPluginIDs: workspace.installedPluginIDSet.union(Set(workspace.enabledCapabilityIDs))
        ).map { blocker in
            switch blocker {
            case .appTooOld(let required, let current):
                return "\(package.name) requires ASTRA \(required) or newer. Current version is \(current)."
            case .missingDependency(let dependency):
                return "\(package.name) requires \(dependency) to be installed first."
            case .conflictsWith(let conflict):
                return "\(package.name) conflicts with \(conflict)."
            }
        }
    }
}
