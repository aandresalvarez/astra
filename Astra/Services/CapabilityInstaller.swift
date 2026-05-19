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
        baseURLOverrides: [String: String] = [:],
        policyContext: CapabilityCatalogPolicyContext? = nil,
        traceID: String? = nil
    ) throws -> InstallationResult {
        let blockers = uniqueMessages(
            policyBlockerMessages(for: package, context: policyContext)
                + installBlockerMessages(for: package, in: workspace, baseURLOverrides: baseURLOverrides)
        )
        guard blockers.isEmpty else {
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "blocked"
            fields["blocker_count"] = String(blockers.count)
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .warning)
            throw InstallationError.blocked(blockers)
        }
        do {
            try library.install(package)
        } catch {
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "library_install_failed"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
        let result = try enable(
            package,
            in: workspace,
            modelContext: modelContext,
            credentialInputs: credentialInputs,
            configInputs: configInputs,
            baseURLOverrides: baseURLOverrides,
            policyContext: policyContext,
            auditSource: "install",
            traceID: traceID
        )
        var installedFields = [
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString
        ]
        installedFields.merge(CapabilityAudit.governanceFields(package.governance), uniquingKeysWith: { _, new in new })
        if let traceID { installedFields["trace_id"] = traceID }
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: installedFields)
        return result
    }

    @discardableResult
    func enable(
        _ package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
        policyContext: CapabilityCatalogPolicyContext? = nil,
        auditSource: String = "enable",
        traceID: String? = nil
    ) throws -> InstallationResult {
        var startFields = capabilityFields(for: package, workspace: workspace, source: auditSource)
        if let traceID { startFields["trace_id"] = traceID }
        startFields["credential_input_count"] = String(credentialInputs.count)
        startFields["config_input_count"] = String(configInputs.count)
        startFields["base_url_override_count"] = String(baseURLOverrides.count)
        AppLogger.audit(.capabilityEnableStarted, category: "Capabilities", fields: startFields)

        let blockers = uniqueMessages(policyBlockerMessages(for: package, context: policyContext))
        guard blockers.isEmpty else {
            var fields = capabilityFields(for: package, workspace: workspace, source: auditSource)
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_blocked"
            fields["blocker_count"] = String(blockers.count)
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .warning)
            throw InstallationError.blocked(blockers)
        }

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
                package: package,
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
                    package: package,
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
                    package: package,
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
            let tool = upsertGlobalTool(pluginTool, package: package, modelContext: modelContext)
            if let primarySkill, tool.skill == nil {
                tool.skill = primarySkill
            }
            if primarySkill == nil {
                appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
            }
            appendUnique(tool.id, to: &localToolIDs)
        }

        for pluginTemplate in package.templates {
            let template = upsertWorkspaceTemplate(pluginTemplate, package: package, workspace: workspace, modelContext: modelContext)
            appendUnique(template.id, to: &templateIDs)
        }

        appendUnique(package.id, to: &workspace.enabledCapabilityIDs)
        workspace.recordInstalledPlugin(id: package.id, version: package.version)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        var enabledFields = [
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(skillIDs.count),
            "connectors_count": String(connectorIDs.count),
            "tools_count": String(localToolIDs.count),
            "templates_count": String(templateIDs.count),
            "enabled_capability_ids": CapabilityAudit.compactNames(workspace.enabledCapabilityIDs)
        ]
        enabledFields.merge(CapabilityAudit.governanceFields(package.governance), uniquingKeysWith: { _, new in new })
        if let traceID { enabledFields["trace_id"] = traceID }
        AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: enabledFields)

        return InstallationResult(
            packageID: package.id,
            skillIDs: skillIDs,
            connectorIDs: connectorIDs,
            localToolIDs: localToolIDs,
            templateIDs: templateIDs
        )
    }

    private func capabilityFields(
        for package: PluginPackage,
        workspace: Workspace,
        source: String
    ) -> [String: String] {
        CapabilityAudit.packageFields(
            packageID: package.id,
            packageName: package.name,
            packageVersion: package.version,
            workspace: workspace,
            source: source,
            skillsCount: package.skills.count,
            connectorsCount: package.connectors.count,
            toolsCount: package.localTools.count,
            templatesCount: package.templates.count,
            governance: package.governance
        )
    }

    private func upsertGlobalSkill(
        _ pluginSkill: PluginSkill,
        package: PluginPackage,
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
        CapabilityResourceOrigin.stamp(
            skill,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginSkill)
        )
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
        package: PluginPackage,
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
        CapabilityResourceOrigin.stamp(
            connector,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginConnector)
        )
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
        package: PluginPackage,
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
        CapabilityResourceOrigin.stamp(
            connector,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginConnector)
        )
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

    private func upsertGlobalTool(
        _ pluginTool: PluginLocalTool,
        package: PluginPackage,
        modelContext: ModelContext
    ) -> LocalTool {
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
        CapabilityResourceOrigin.stamp(
            tool,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginTool)
        )
        tool.updatedAt = Date()
        return tool
    }

    private func upsertWorkspaceTemplate(
        _ pluginTemplate: PluginTemplate,
        package: PluginPackage,
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
        CapabilityResourceOrigin.stamp(
            template,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginTemplate)
        )
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

    private func installBlockerMessages(
        for package: PluginPackage,
        in workspace: Workspace,
        baseURLOverrides: [String: String]
    ) -> [String] {
        let dependencyMessages = package.installBlockers(
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
        return dependencyMessages
            + unsafeLocalToolMessages(for: package)
            + unsafeConnectorMessages(for: package, baseURLOverrides: baseURLOverrides)
            + unsafeMCPServerMessages(for: package)
    }

    private func policyBlockerMessages(
        for package: PluginPackage,
        context: CapabilityCatalogPolicyContext?
    ) -> [String] {
        guard let context else { return [] }
        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
        guard !decision.canEnable else { return [] }
        return decision.blockerMessages
    }

    private func unsafeLocalToolMessages(for package: PluginPackage) -> [String] {
        package.localTools.compactMap { tool in
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = LocalToolSecurityPolicy.unsafeCommandReason(command) {
                return "\(package.name) defines local tool \(tool.name) with an unsafe command: \(reason). Put flags or shell syntax in reviewed documentation, not in the command field."
            }
            if let reason = LocalToolSecurityPolicy.unsafeArgumentsReason(tool.arguments) {
                return "\(package.name) defines local tool \(tool.name) with unsafe default arguments: \(reason). Keep shell control syntax out of package defaults."
            }
            return nil
        }
    }

    private func unsafeConnectorMessages(
        for package: PluginPackage,
        baseURLOverrides: [String: String]
    ) -> [String] {
        package.connectors.compactMap { connector in
            let baseURL = baseURLOverrides[connector.name] ?? connector.baseURL
            guard let violation = ConnectorSecurityPolicy.credentialTransportViolation(
                baseURL: baseURL,
                authMethod: connector.authMethod,
                credentialKeys: connector.credentialHints.map(\.key)
            ) else {
                return nil
            }
            return "\(package.name) defines connector \(connector.name) with an unsafe credential transport. \(violation)"
        }
    }

    private func unsafeMCPServerMessages(for package: PluginPackage) -> [String] {
        package.mcpServers.compactMap { server in
            switch server.transport {
            case .stdio:
                let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let reason = LocalToolSecurityPolicy.unsafeCommandReason(command) {
                    return "\(package.name) defines MCP server \(server.displayName) with an unsafe command: \(reason)."
                }
                if let reason = LocalToolSecurityPolicy.unsafeArgumentsReason(server.arguments.joined(separator: " ")) {
                    return "\(package.name) defines MCP server \(server.displayName) with unsafe default arguments: \(reason)."
                }
            case .http, .sse:
                guard let url = server.url,
                      let scheme = url.scheme?.lowercased() else {
                    return "\(package.name) defines MCP server \(server.displayName) with a missing or invalid remote URL."
                }
                if scheme == "https" || (scheme == "http" && isLoopbackHost(url.host)) {
                    return nil
                }
                return "\(package.name) defines MCP server \(server.displayName) with an unsafe remote URL. Remote MCP URLs must use HTTPS, except loopback HTTP for local development."
            }
            return nil
        }
    }

    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
    }

    private func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }
}
