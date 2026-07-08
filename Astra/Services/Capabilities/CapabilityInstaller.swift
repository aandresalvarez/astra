import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
struct CapabilityInstaller {
    enum InstallationError: Error, Equatable, LocalizedError {
        case blocked([String])
        case persistenceFailed(packageID: String)
        case credentialSaveFailed(packageID: String, key: String)

        var errorDescription: String? {
            switch self {
            case .blocked(let messages):
                return messages.joined(separator: "\n")
            case .persistenceFailed(let id):
                return "Enabling \(id) could not be saved. Try again."
            case .credentialSaveFailed(let id, let key):
                return "Enabling \(id) could not save the \(key) credential. Try again."
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
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext? = nil,
        traceID: String? = nil
    ) throws -> InstallationResult {
        let effectivePolicyContext = policyContext ?? defaultPolicyContext(for: workspace)
        let blockers = uniqueMessages(
            policyBlockerMessages(for: package, context: effectivePolicyContext)
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
        // Snapshot the pre-install library state so a failed enable can be
        // compensated instead of leaving an orphaned or overwritten file.
        let packageStorageSnapshot = library.makePackageStorageSnapshot(for: package.id)
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
        let result: InstallationResult
        do {
            result = try enable(
                package,
                in: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: allowCredentialUserInteraction,
                policyContext: effectivePolicyContext,
                auditSource: "install",
                traceID: traceID
            )
        } catch {
            library.restorePackageStorage(packageStorageSnapshot)
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_failed_library_rolled_back"
            fields["restored_previous_file"] = packageStorageSnapshot.snapshotURL == nil ? "false" : "true"
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
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
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext? = nil,
        auditSource: String = "enable",
        traceID: String? = nil,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = CapabilityPersistence.defaultPersist
    ) throws -> InstallationResult {
        var startFields = capabilityFields(for: package, workspace: workspace, source: auditSource)
        if let traceID { startFields["trace_id"] = traceID }
        startFields["credential_input_count"] = String(credentialInputs.count)
        startFields["config_input_count"] = String(configInputs.count)
        startFields["base_url_override_count"] = String(baseURLOverrides.count)
        AppLogger.audit(.capabilityEnableStarted, category: "Capabilities", fields: startFields)

        let effectivePolicyContext = policyContext ?? defaultPolicyContext(for: workspace)
        let blockers = uniqueMessages(policyBlockerMessages(for: package, context: effectivePolicyContext))
        guard blockers.isEmpty else {
            var fields = capabilityFields(for: package, workspace: workspace, source: auditSource)
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_blocked"
            fields["blocker_count"] = String(blockers.count)
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .warning)
            throw InstallationError.blocked(blockers)
        }

        let membershipSnapshot = WorkspaceCapabilityMembershipSnapshot(workspace)
        // Everything from here through persist() is one transaction: staging a
        // skill/connector/tool can throw (credential save denied, activation
        // swap failure, ...) partway through the loops below, after earlier
        // iterations already inserted records and mutated the workspace's
        // membership arrays. Without a shared catch, only a persist() failure
        // rolled back — any other mid-loop throw left those partial inserts
        // and membership mutations in place for a later unrelated save to
        // persist as orphaned, credential-less resources.
        do {
            var skillIDs: [UUID] = []
            var connectorIDs: [UUID] = []
            var localToolIDs: [UUID] = []
            var templateIDs: [UUID] = []
            var skillsByName: [String: Skill] = [:]

            let skillConfigInputs = package.connectors.isEmpty ? configInputs : [:]
            let packageEnvironmentKeys = package.skills.flatMap(\.environmentKeys)

            for pluginSkill in package.skills {
                let skill = try upsertGlobalSkill(
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
                    connector = try upsertWorkspaceConnector(
                        pluginConnector,
                        package: package,
                        workspace: workspace,
                        modelContext: modelContext,
                        credentialInputs: credentialInputs,
                        configInputs: configInputs,
                        extraConfigKeys: packageEnvironmentKeys,
                        baseURL: baseURL,
                        allowCredentialUserInteraction: allowCredentialUserInteraction
                    )
                    try removeMatchingGlobalConnectorActivation(
                        pluginConnector,
                        from: workspace,
                        modelContext: modelContext
                    )
                } else {
                    connector = try upsertGlobalConnector(
                        pluginConnector,
                        package: package,
                        modelContext: modelContext,
                        credentialInputs: credentialInputs,
                        configInputs: configInputs,
                        extraConfigKeys: packageEnvironmentKeys,
                        baseURL: baseURL,
                        allowCredentialUserInteraction: allowCredentialUserInteraction
                    )
                    if let primarySkill, connector.skill == nil {
                        connector.skill = primarySkill
                    }
                    appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
                }
                appendUnique(connector.id, to: &connectorIDs)
            }

            for pluginTool in package.localTools {
                let tool = try upsertGlobalTool(pluginTool, package: package, modelContext: modelContext)
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
            guard persist(workspace, modelContext) else {
                throw InstallationError.persistenceFailed(packageID: package.id)
            }
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
        } catch {
            // Reporting success (or even a clean failure) while leaving a
            // partial stage in place would strand the library file and any
            // saved keychain credentials against unsaved/orphaned records.
            // rollback() drops the inserted resources; restore() undoes the
            // membership-array mutations it does not revert.
            modelContext.rollback()
            membershipSnapshot.restore(to: workspace)
            var fields = capabilityFields(for: package, workspace: workspace, source: auditSource)
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_failed_rolled_back"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
    }

    /// Compensation for a failed enable after the library file was written:
    /// restore the pre-install bytes, or remove the file if this was a fresh
    /// install, so the catalog never shows an installed-but-never-enabled
    /// package.
    static func restoreLibraryFile(previousData: Data?, fileExistedBefore: Bool, at url: URL) {
        if let previousData {
            try? previousData.write(to: url, options: [.atomic])
        } else if !fileExistedBefore {
            // Only a genuinely fresh install removes the file. A nil snapshot
            // of a file that DID exist means the pre-install read failed —
            // deleting then would destroy the user's previous package.
            try? FileManager.default.removeItem(at: url)
        }
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
    ) throws -> Skill {
        let skill = try existingGlobalSkill(named: pluginSkill.name, modelContext: modelContext) ?? Skill(
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
        baseURL: String,
        allowCredentialUserInteraction: Bool
    ) throws -> Connector {
        let connector = try existingGlobalConnector(
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
        try saveConnectorCredentials(
            connector,
            hints: pluginConnector.credentialHints,
            credentialInputs: credentialInputs,
            allowCredentialUserInteraction: allowCredentialUserInteraction,
            packageID: package.id
        )
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
        baseURL: String,
        allowCredentialUserInteraction: Bool
    ) throws -> Connector {
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
        try saveConnectorCredentials(
            connector,
            hints: pluginConnector.credentialHints,
            credentialInputs: credentialInputs,
            allowCredentialUserInteraction: allowCredentialUserInteraction,
            packageID: package.id
        )
        return connector
    }

    /// Saves each hinted credential in order, and on a mid-batch failure
    /// deletes the Keychain entries this call itself just saved before
    /// throwing. Without this, an earlier hint's successful Keychain write
    /// survives a later hint's failure: `enable()`'s catch only calls
    /// `modelContext.rollback()`, which reverts the connector's
    /// `credentialKeys` array but never touches Keychain, orphaning that
    /// secret under a connector the user can no longer see or manage.
    private func saveConnectorCredentials(
        _ connector: Connector,
        hints: [PluginConnector.CredentialHint],
        credentialInputs: [String: String],
        allowCredentialUserInteraction: Bool,
        packageID: String
    ) throws {
        var savedKeysThisCall: [String] = []
        for hint in hints {
            guard let value = credentialInputs[hint.key], !value.isEmpty else { continue }
            guard connector.saveCredential(
                key: hint.key,
                value: value,
                allowUserInteraction: allowCredentialUserInteraction
            ) else {
                for savedKey in savedKeysThisCall {
                    connector.removeCredential(forKey: savedKey)
                }
                throw InstallationError.credentialSaveFailed(packageID: packageID, key: hint.key)
            }
            savedKeysThisCall.append(hint.key)
        }
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
    ) throws {
        guard !workspace.enabledGlobalConnectorIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
        let globalConnectors = try modelContext.fetch(descriptor)
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
    ) throws -> LocalTool {
        let tool = try existingGlobalTool(
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

    private func existingGlobalSkill(named name: String, modelContext: ModelContext) throws -> Skill? {
        let descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate {
                $0.name == name &&
                $0.isGlobal
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func existingGlobalConnector(
        name: String,
        serviceType: String,
        baseURL: String,
        modelContext: ModelContext
    ) throws -> Connector? {
        let descriptor = FetchDescriptor<Connector>(
            predicate: #Predicate {
                $0.name == name &&
                $0.serviceType == serviceType &&
                $0.baseURL == baseURL &&
                $0.isGlobal
            }
        )
        return try modelContext.fetch(descriptor).first
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
    ) throws -> LocalTool? {
        let descriptor = FetchDescriptor<LocalTool>(
            predicate: #Predicate {
                $0.name == name &&
                $0.toolType == toolType &&
                $0.command == command &&
                $0.isGlobal
            }
        )
        return try modelContext.fetch(descriptor).first
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
        context: CapabilityCatalogPolicyContext
    ) -> [String] {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
        guard !decision.canEnable else { return [] }
        return decision.blockerMessages
    }

    private func defaultPolicyContext(for workspace: Workspace) -> CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: appVersion,
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    private func unsafeLocalToolMessages(for package: PluginPackage) -> [String] {
        package.localTools.compactMap { tool in
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(command: command, arguments: tool.arguments) {
                return "\(package.name) defines local tool \(tool.name) with an unsafe command or default arguments: \(reason). Put flags or shell syntax in reviewed documentation, not in package defaults."
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
                if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
                    command: command,
                    arguments: server.arguments.joined(separator: " ")
                ) {
                    return "\(package.name) defines MCP server \(server.displayName) with an unsafe command or default arguments: \(reason)."
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
