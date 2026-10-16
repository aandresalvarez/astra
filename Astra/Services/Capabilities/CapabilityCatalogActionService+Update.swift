import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

extension CapabilityCatalogActionService {
    /// Plugins 2.0 Update: re-runs Add with the library's definition, which
    /// rewrites the plugin's skills, connectors, tools and templates and records
    /// the new version. This visible step replaces the startup repair that
    /// rewrote definitions silently on every launch.
    ///
    /// The shared skills, accounts and tools are the same records in every
    /// workspace, so an Update reaches every workspace that has the plugin on,
    /// starting with this one: each records the new version and retires what
    /// the new version dropped, instead of one workspace changing what another
    /// still records as the old version.
    ///
    /// What the person configured survives: a workspace account keeps its
    /// base URL and settings (and stays in its workspace), and a shared account
    /// or skill keeps the values of every key the new version still declares.
    @discardableResult
    func update(
        _ package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        // Shared values are read once, before the first re-add resets them.
        let shared = try PluginUpdateSetup.captureShared(package, modelContext: modelContext)
        let result = try updateOne(
            package, in: workspace, shared: shared, modelContext: modelContext,
            policyContext: policyContext, approvalStore: approvalStore, traceID: traceID
        )
        let others = try modelContext.fetch(FetchDescriptor<Workspace>()).filter {
            $0.id != workspace.id && $0.isLive && $0.capabilityActivation.capabilityIDs.contains(package.id)
        }
        for other in others {
            try updateOne(
                package, in: other, shared: shared, modelContext: modelContext,
                policyContext: .currentUser(workspace: other, approvalRecords: approvalStore.records()),
                approvalStore: approvalStore, traceID: traceID
            )
        }
        return result
    }

    @discardableResult
    private func updateOne(
        _ package: PluginPackage,
        in workspace: Workspace,
        shared: PluginUpdateSetup,
        modelContext: ModelContext,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore,
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        let previousVersion = workspace.capabilityActivation.installedVersion(of: package.id)
        let inputs = PluginUpdateSetup.workspaceInputs(package, workspace: workspace)
        let result = try add(
            package,
            workspace: workspace,
            modelContext: modelContext,
            policyContext: policyContext,
            approvalStore: approvalStore,
            configInputs: inputs.workspaceConfigInputs,
            baseURLOverrides: inputs.workspaceBaseURLs,
            traceID: traceID
        )
        let activation = WorkspaceCapabilityActivation.snapshot(workspace)
        try shared.restoreShared(modelContext: modelContext)
        let pruned = try PluginUpdateSetup.prune(package, result: result, workspace: workspace, modelContext: modelContext)
        // Workspace accounts it retires are deleted the way a disable deletes
        // them: their saved keys are cleaned only once the deletion is saved.
        let saved = ConnectorCredentialCleanup.deleteThenClean(pruned.connectorCleanups, modelContext: modelContext) {
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: workspace,
                modelContext: modelContext,
                auditFields: ["source": "plugins_update", "package_id": package.id]
            )
        }
        guard saved else {
            // Add already saved the new definition and version. Put the old
            // version back so Update stays offered and a retry finishes the
            // cleanup, rather than reading as done.
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(activation, to: workspace)
            WorkspaceCapabilityActivation.mutate(workspace) { state in
                if let previousVersion {
                    state.recordInstalledPlugin(id: package.id, version: previousVersion)
                } else {
                    state.removeInstalledPlugin(id: package.id)
                }
            }
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: workspace,
                modelContext: modelContext,
                auditFields: ["source": "plugins_update", "package_id": package.id, "result": "update_rolled_back"]
            )
            throw CapabilityInstaller.InstallationError.persistenceFailed(packageID: package.id)
        }
        AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
            "source": "plugins_update",
            "package_id": package.id,
            "package_version": package.version,
            "previous_version": previousVersion ?? "",
            "workspace_id": workspace.id.uuidString,
            "pruned_count": String(pruned.count),
            "trace_id": traceID
        ])
        return result
    }
}

/// The configured state an Update must carry across, and the leftovers it
/// must retire.
@MainActor
struct PluginUpdateSetup {
    var workspaceConfigInputs: [String: String] = [:]
    var workspaceBaseURLs: [String: String] = [:]
    private var sharedConnectorValues: [UUID: [String: String]] = [:]
    private var sharedSkillValues: [UUID: [String: String]] = [:]

    static func workspaceInputs(_ package: PluginPackage, workspace: Workspace) -> PluginUpdateSetup {
        var setup = PluginUpdateSetup()
        for spec in package.connectors {
            guard let existing = workspace.connectors.first(where: { $0.name == spec.name && $0.serviceType == spec.serviceType })
            else { continue }
            // Passing the URL keeps the account workspace-scoped, as it was.
            setup.workspaceBaseURLs[spec.name] = existing.baseURL
            for (key, value) in zip(existing.configKeys, existing.configValues) where !value.isEmpty {
                setup.workspaceConfigInputs[key] = value
            }
        }
        return setup
    }

    static func captureShared(_ package: PluginPackage, modelContext: ModelContext) throws -> PluginUpdateSetup {
        var setup = PluginUpdateSetup()
        let packageID = package.id
        for connector in try modelContext.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal }))
        where connector.originPackageID == packageID {
            setup.sharedConnectorValues[connector.id] = Dictionary(
                zip(connector.configKeys, connector.configValues).filter { !$0.1.isEmpty },
                uniquingKeysWith: { first, _ in first }
            )
        }
        for skill in try modelContext.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal }))
        where skill.originPackageID == packageID {
            setup.sharedSkillValues[skill.id] = Dictionary(
                zip(skill.environmentKeys, skill.environmentValues).filter { !$0.1.isEmpty },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return setup
    }

    /// Puts back the values the re-add reset on shared accounts and skills,
    /// for the keys the new version still declares.
    func restoreShared(modelContext: ModelContext) throws {
        for connector in try modelContext.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal })) {
            guard let values = sharedConnectorValues[connector.id] else { continue }
            connector.configValues = zip(connector.configKeys, connector.configValues).map { values[$0.0] ?? $0.1 }
        }
        for skill in try modelContext.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal })) {
            guard let values = sharedSkillValues[skill.id] else { continue }
            skill.environmentValues = zip(skill.environmentKeys, skill.environmentValues).map { values[$0.0] ?? $0.1 }
        }
    }

    struct Pruned {
        var count = 0
        var connectorCleanups: [ConnectorKeychainCleanup] = []
    }

    /// Retires what the package owns but the new version did not produce.
    static func prune(
        _ package: PluginPackage,
        result: CapabilityInstaller.InstallationResult,
        workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Pruned {
        let packageID = package.id
        var pruned = Pruned()
        let skillKind = CapabilityResourceComponentKind.skill.rawValue
        let staleSkills = Set(try modelContext.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal }))
            .filter { $0.originPackageID == packageID && $0.originComponentKind == skillKind && !result.skillIDs.contains($0.id) }
            .map(\.id.uuidString))
        let staleConnectors = try modelContext.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal }))
            .filter { $0.originPackageID == packageID && !result.connectorIDs.contains($0.id) }
        let staleTools = try modelContext.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal }))
            .filter { $0.originPackageID == packageID && !result.localToolIDs.contains($0.id) }
        let staleConnectorIDs = Set(staleConnectors.map(\.id.uuidString))
        let staleToolIDs = Set(staleTools.map(\.id.uuidString))
        WorkspaceCapabilityActivation.mutate(workspace) { state in
            let before = state.globalSkillIDs.count + state.globalConnectorIDs.count + state.globalToolIDs.count
            state.globalSkillIDs.removeAll { staleSkills.contains($0) }
            state.globalConnectorIDs.removeAll { staleConnectorIDs.contains($0) }
            state.globalToolIDs.removeAll { staleToolIDs.contains($0) }
            pruned.count += before - (state.globalSkillIDs.count + state.globalConnectorIDs.count + state.globalToolIDs.count)
        }
        // A shared account or tool reaches a run through its skill too.
        for connector in staleConnectors where connector.skill != nil {
            connector.skill = nil
            pruned.count += 1
        }
        for tool in staleTools where tool.skill != nil {
            tool.skill = nil
            pruned.count += 1
        }
        for connector in workspace.connectors
        where connector.originPackageID == packageID && !result.connectorIDs.contains(connector.id) {
            pruned.connectorCleanups.append(connector.keychainCleanup)
            modelContext.delete(connector)
            pruned.count += 1
        }
        for template in workspace.templates
        where template.originPackageID == packageID && !result.templateIDs.contains(template.id) {
            modelContext.delete(template)
            pruned.count += 1
        }
        return pruned
    }
}
