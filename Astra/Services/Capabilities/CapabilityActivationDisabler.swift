import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
struct CapabilityActivationDisabler {
    struct Result: Equatable {
        var packageID: String
        var disabledSkillIDs: [UUID] = []
        var disabledConnectorIDs: [UUID] = []
        var disabledToolIDs: [UUID] = []
        var removedWorkspaceSkillIDs: [UUID] = []
        var removedWorkspaceConnectorIDs: [UUID] = []
    }

    @discardableResult
    func disable(
        _ package: PluginPackage,
        in workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        modelContext: ModelContext,
        availablePackages: [PluginPackage] = CapabilityRuntimeResourceMatcher.packageDefinitions(),
        persist: @MainActor (Workspace?, ModelContext) -> Bool = CapabilityPersistence.defaultPersist
    ) -> Result {
        let membershipSnapshot = WorkspaceCapabilityMembershipSnapshot(workspace)
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )
        let remainingPackages = remainingEnabledPackages(
            excluding: package,
            workspace: workspace,
            capabilities: capabilities,
            availablePackages: availablePackages
        )
        var result = Result(packageID: package.id)

        workspace.enabledCapabilityIDs.removeAll { $0 == package.id }

        let removableGlobalSkillIDs = Set(state.linkedSkills
            .filter { skill in
                skill.isGlobal && !isClaimedByRemainingPackages(skill, excluding: package, remainingPackages: remainingPackages)
            }
            .map { $0.id.uuidString })
        result.disabledSkillIDs = removableGlobalSkillIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalSkillIDs.removeAll { id in
            removableGlobalSkillIDs.contains(id)
        }

        let removableGlobalConnectorIDs = Set(state.linkedConnectors
            .filter { connector in
                connector.isGlobal && !isClaimedByRemainingPackages(connector, excluding: package, remainingPackages: remainingPackages)
            }
            .map { $0.id.uuidString })
        result.disabledConnectorIDs = removableGlobalConnectorIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalConnectorIDs.removeAll { id in
            removableGlobalConnectorIDs.contains(id)
        }

        let removableGlobalToolIDs = Set(state.linkedTools
            .filter { tool in
                tool.isGlobal && !isClaimedByRemainingPackages(tool, excluding: package, remainingPackages: remainingPackages)
            }
            .map { $0.id.uuidString })
        result.disabledToolIDs = removableGlobalToolIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalToolIDs.removeAll { id in
            removableGlobalToolIDs.contains(id)
        }

        // Keychain entries are wiped only after the SwiftData deletes are
        // saved; otherwise a failed save would leave connector/skill records
        // that look configured but whose credentials are gone.
        var pendingKeychainCleanups: [() -> Void] = []

        for connector in state.linkedConnectors where !connector.isGlobal {
            guard !isClaimedByRemainingPackages(connector, excluding: package, remainingPackages: remainingPackages) else { continue }
            pendingKeychainCleanups.append { connector.cleanupKeychain() }
            result.removedWorkspaceConnectorIDs.append(connector.id)
            modelContext.delete(connector)
        }

        let remainingExplicitPackages = remainingPackages.filter { !$0.isSyntheticWorkspaceSkillPackage }
        for skill in state.linkedSkills where !skill.isGlobal {
            guard !isClaimedByRemainingPackages(skill, excluding: package, remainingPackages: remainingExplicitPackages) else { continue }
            pendingKeychainCleanups.append { skill.cleanupKeychain() }
            result.removedWorkspaceSkillIDs.append(skill.id)
            modelContext.delete(skill)
        }

        workspace.updatedAt = Date()

        // Always persist: disable mutates the workspace membership arrays
        // (enabledCapabilityIDs / enabled-global IDs) even when no
        // keychain-backed workspace resource is deleted — e.g. global-only
        // or MCP-only packages. Skipping the save there would make the
        // disable look applied in memory but never reach SwiftData / the
        // exported config. Keychain cleanup stays gated on a successful save.
        if persist(workspace, modelContext) {
            pendingKeychainCleanups.forEach { $0() }
        } else {
            // Failed save: revert the pending deletes and the workspace
            // membership arrays (which rollback does not restore) so the
            // package reads as still enabled (truthful) and no keychain
            // credential is orphaned by a later unrelated save.
            modelContext.rollback()
            membershipSnapshot.restore(to: workspace)
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "package_disable",
                "package_id": package.id,
                "result": "save_failed_disable_rolled_back",
                "deferred_cleanup_count": String(pendingKeychainCleanups.count)
            ], level: .error)
            return Result(packageID: package.id)
        }
        return result
    }

    private func remainingEnabledPackages(
        excluding package: PluginPackage,
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        availablePackages: [PluginPackage]
    ) -> [PluginPackage] {
        let enabledIDs = Set(workspace.enabledCapabilityIDs).subtracting([package.id])
        let enabledCatalogPackages = availablePackages.filter { enabledIDs.contains($0.id) }
        // Only the synthetic standalone-skill projections. Catalog packages
        // count as remaining solely via explicit enablement above — a
        // resource-projected "still configured" catalog package would
        // otherwise keep a shared resource alive after every package
        // claiming it was disabled (mutual-claim deadlock).
        let syntheticPackages = CapabilityCatalogInventory.configuredPackages(
            catalogPackages: availablePackages,
            capabilities: capabilities,
            workspace: workspace
        )
        .filter { $0.id != package.id && $0.isSyntheticWorkspaceSkillPackage }
        return uniquePackages(enabledCatalogPackages + syntheticPackages)
    }

    private func claims(_ skill: Skill, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(skill, packageID: package.id) {
            return true
        }
        return package.skills.contains {
            CapabilityRuntimeResourceMatcher.skillMatches($0, skill: skill)
        }
    }

    private func claims(_ connector: Connector, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(connector, packageID: package.id) {
            return true
        }
        return package.connectors.contains {
            CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector)
        }
    }

    private func claims(_ tool: LocalTool, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(tool, packageID: package.id) {
            return true
        }
        return package.localTools.contains {
            CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool)
        }
    }

    private func isClaimedByRemainingPackages(
        _ skill: Skill,
        excluding package: PluginPackage,
        remainingPackages: [PluginPackage]
    ) -> Bool {
        remainingPackages.contains { remaining in
            // Synthetic standalone-skill packages only preserve user-created
            // resources. A package-originated resource is governed by real
            // package claims, so a lingering synthetic self-claim must not
            // keep it active after its last claiming package is disabled.
            if CapabilityResourceOrigin.hasOrigin(skill),
               remaining.isSyntheticWorkspaceSkillPackage {
                return false
            }
            return claims(skill, package: remaining)
        }
    }

    private func isClaimedByRemainingPackages(
        _ connector: Connector,
        excluding package: PluginPackage,
        remainingPackages: [PluginPackage]
    ) -> Bool {
        remainingPackages.contains { remaining in
            // Synthetic standalone-skill packages only preserve user-created
            // resources. A package-originated resource is governed by real
            // package claims, so a lingering synthetic self-claim must not
            // keep it active after its last claiming package is disabled.
            if CapabilityResourceOrigin.hasOrigin(connector),
               remaining.isSyntheticWorkspaceSkillPackage {
                return false
            }
            return claims(connector, package: remaining)
        }
    }

    private func isClaimedByRemainingPackages(
        _ tool: LocalTool,
        excluding package: PluginPackage,
        remainingPackages: [PluginPackage]
    ) -> Bool {
        remainingPackages.contains { remaining in
            // Synthetic standalone-skill packages only preserve user-created
            // resources. A package-originated resource is governed by real
            // package claims, so a lingering synthetic self-claim must not
            // keep it active after its last claiming package is disabled.
            if CapabilityResourceOrigin.hasOrigin(tool),
               remaining.isSyntheticWorkspaceSkillPackage {
                return false
            }
            return claims(tool, package: remaining)
        }
    }

    private func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}

private extension PluginPackage {
    var isSyntheticWorkspaceSkillPackage: Bool {
        id.hasPrefix("skill.") && (sourceMetadata?.kind == "workspace" || sourceMetadata?.kind == "shared")
    }
}
