import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
enum CapabilityDefinitionRepairService {
    static func refreshInstalledApprovedDefinitions(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        approvedPackages: [PluginPackage]
    ) {
        let installedIDs = Set(library.installedPackages().map(\.id))
        guard !installedIDs.isEmpty else { return }

        let skills: [Skill]
        let connectors: [Connector]
        let workspaces: [Workspace]
        do {
            skills = try modelContext.fetch(FetchDescriptor<Skill>())
            connectors = try modelContext.fetch(FetchDescriptor<Connector>())
            workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        } catch {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "approved_capability_definitions",
                "stage": "fetch_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }

        var updated = 0
        for package in approvedPackages where installedIDs.contains(package.id) {
            let serviceTypes = Set(package.connectors.map { normalizedServiceType($0.serviceType) })
            for pluginSkill in package.skills {
                for skill in skills where shouldRefresh(
                    skill,
                    pluginSkill: pluginSkill,
                    package: package,
                    serviceTypes: serviceTypes,
                    connectors: connectors
                ) {
                    if apply(pluginSkill, to: skill) {
                        updated += 1
                    }
                }
            }
            updated += repairEnabledPackageActivations(
                package,
                skills: skills,
                connectors: connectors,
                workspaces: workspaces
            )
        }

        guard updated > 0 else { return }
        // This startup repair mutates MULTIPLE workspaces, so there is no single export
        // target; `workspace: nil` routes the save through the coordinator (durable +
        // uniformly logged) without picking an arbitrary workspace to mirror — each
        // workspace's JSON mirror refreshes on its next own save, exactly as before.
        // On failure the coordinator logs the error type under the persistence events.
        if WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: nil,
            modelContext: modelContext,
            auditFields: ["migration": "approved_capability_definitions"]
        ) {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "approved_capability_definitions",
                "skill_count": String(updated)
            ])
        } else {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "approved_capability_definitions",
                "stage": "save_failed"
            ], level: .error)
        }
    }

    private static func repairEnabledPackageActivations(
        _ package: PluginPackage,
        skills: [Skill],
        connectors: [Connector],
        workspaces: [Workspace]
    ) -> Int {
        let packageSkillNames = Set(package.skills.map { normalizedName($0.name) })
        let packageSkills = skills.filter { skill in
            skill.isGlobal && packageSkillNames.contains(normalizedName(skill.name))
        }
        guard !packageSkills.isEmpty else { return 0 }

        let packageSkillIDs = Set(packageSkills.map(\.id.uuidString))
        let linkedGlobalConnectors = connectors.filter { connector in
            guard connector.isGlobal else { return false }
            guard let skill = connector.skill else { return false }
            return packageSkillIDs.contains(skill.id.uuidString)
        }

        var updated = 0
        for workspace in workspaces where workspace.enabledCapabilityIDs.contains(package.id) {
            var changed = false
            for skill in packageSkills {
                let id = skill.id.uuidString
                if !workspace.enabledGlobalSkillIDs.contains(id) {
                    workspace.enabledGlobalSkillIDs.append(id)
                    changed = true
                }
            }
            for connector in linkedGlobalConnectors {
                let id = connector.id.uuidString
                if !workspace.enabledGlobalConnectorIDs.contains(id) {
                    workspace.enabledGlobalConnectorIDs.append(id)
                    changed = true
                }
            }
            if changed {
                workspace.updatedAt = Date()
                updated += 1
            }
        }
        return updated
    }

    private static func shouldRefresh(
        _ skill: Skill,
        pluginSkill: PluginSkill,
        package: PluginPackage,
        serviceTypes: Set<String>,
        connectors: [Connector]
    ) -> Bool {
        guard normalizedName(skill.name) == normalizedName(pluginSkill.name) else { return false }
        guard isLikelyApprovedPackageCopy(skill, pluginSkill: pluginSkill) else { return false }
        if skill.isGlobal { return true }

        guard let workspace = skill.workspace else { return false }
        if workspace.enabledCapabilityIDs.contains(package.id) || workspace.installedPluginIDSet.contains(package.id) {
            return true
        }

        if connectors.contains(where: { connector in
            connector.workspace?.id == workspace.id && serviceTypes.contains(normalizedServiceType(connector.serviceType))
        }) {
            return true
        }

        return skill.behaviorInstructions != pluginSkill.behaviorInstructions
    }

    private static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isLikelyApprovedPackageCopy(_ skill: Skill, pluginSkill: PluginSkill) -> Bool {
        if skill.icon == pluginSkill.icon { return true }
        if skill.skillDescription == pluginSkill.description { return true }

        let currentLead = firstNonEmptyLine(skill.behaviorInstructions)
        let approvedLead = firstNonEmptyLine(pluginSkill.behaviorInstructions)
        return !currentLead.isEmpty && currentLead == approvedLead
    }

    private static func firstNonEmptyLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func apply(_ pluginSkill: PluginSkill, to skill: Skill) -> Bool {
        var changed = false

        if skill.icon != pluginSkill.icon {
            skill.icon = pluginSkill.icon
            changed = true
        }
        if skill.skillDescription != pluginSkill.description {
            skill.skillDescription = pluginSkill.description
            changed = true
        }
        if skill.allowedTools != pluginSkill.allowedTools {
            skill.allowedTools = pluginSkill.allowedTools
            changed = true
        }
        if skill.customTools != pluginSkill.customTools {
            skill.customTools = pluginSkill.customTools
            changed = true
        }
        if skill.behaviorInstructions != pluginSkill.behaviorInstructions {
            skill.behaviorInstructions = pluginSkill.behaviorInstructions
            changed = true
        }

        if updateEnvironmentKeys(pluginSkill, on: skill) {
            changed = true
        }

        if changed {
            skill.updatedAt = Date()
        }
        return changed
    }

    private static func updateEnvironmentKeys(_ pluginSkill: PluginSkill, on skill: Skill) -> Bool {
        guard skill.environmentKeys != pluginSkill.environmentKeys else { return false }

        let existingValues = Dictionary(
            uniqueKeysWithValues: zip(skill.environmentKeys, skill.environmentValues)
        )
        let defaultValues = Dictionary(
            uniqueKeysWithValues: zip(pluginSkill.environmentKeys, pluginSkill.environmentValues)
        )

        skill.environmentKeys = pluginSkill.environmentKeys
        skill.environmentValues = pluginSkill.environmentKeys.map { key in
            existingValues[key] ?? defaultValues[key] ?? ""
        }
        return true
    }
}
