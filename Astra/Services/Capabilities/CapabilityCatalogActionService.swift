import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct CapabilityCatalogCreateActionResult {
    var package: PluginPackage
    var approvalRecordChanged: Bool
    var installedPackage: PluginPackage?
}

@MainActor
struct CapabilityCatalogActionService {
    let installer: CapabilityInstaller
    let creationService: CapabilityPackageCreationService
    let uninstaller: CapabilityUninstaller

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
    ) {
        self.installer = CapabilityInstaller(library: library, appVersion: appVersion)
        self.creationService = CapabilityPackageCreationService(library: library, appVersion: appVersion)
        self.uninstaller = CapabilityUninstaller(library: library)
    }

    /// Writes the package's shareable source JSON to `url`. The exported
    /// form resets governance to draft, so a recipient's import always goes
    /// through their own review — sharing a capability never shares its
    /// approval.
    @discardableResult
    func exportSource(_ package: PluginPackage, to url: URL) throws -> URL {
        let destination = try CapabilityPackageSourceExporter().export(package, to: url)
        AppLogger.audit(.workspaceExported, category: "Capabilities", fields: [
            "source": "capability_source_export",
            "package_id": package.id,
            "package_version": package.version
        ])
        return destination
    }

    @discardableResult
    func enable(
        _ package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext,
        source: String,
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        do {
            let result = try installer.install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: allowCredentialUserInteraction,
                policyContext: policyContext,
                traceID: traceID
            )
            CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
            return result
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: failureFields(
                package: package,
                workspace: workspace,
                source: source,
                traceID: traceID,
                error: error
            ), level: .error)
            throw error
        }
    }

    func create(
        _ package: PluginPackage,
        enableHere: Bool,
        sourceURL: URL?,
        workspace: Workspace,
        modelContext: ModelContext,
        policyContext: CapabilityCatalogPolicyContext,
        allowCredentialUserInteraction: Bool = false,
        traceID: String
    ) throws -> CapabilityCatalogCreateActionResult {
        let source = enableHere ? "create_and_enable" : "create_install_only"
        do {
            let result = try creationService.create(
                package,
                enableHere: enableHere,
                sourceURL: sourceURL,
                workspace: workspace,
                modelContext: modelContext,
                allowCredentialUserInteraction: allowCredentialUserInteraction,
                policyContext: policyContext,
                traceID: traceID
            )
            // Creation always changes the global library. The creation service
            // owns that event; this additional scoped event represents only
            // the optional workspace enablement.
            if enableHere {
                CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
            }
            return CapabilityCatalogCreateActionResult(
                package: result.package,
                approvalRecordChanged: result.approvalRecord != nil,
                installedPackage: enableHere ? result.package : nil
            )
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: failureFields(
                package: package,
                workspace: workspace,
                source: source,
                traceID: traceID,
                sourceURL: sourceURL,
                error: error
            ), level: .error)
            throw error
        }
    }

    @discardableResult
    func remove(
        _ package: PluginPackage,
        modelContext: ModelContext
    ) throws -> CapabilityUninstaller.RemovalResult {
        try uninstaller.remove(package, modelContext: modelContext)
    }

    /// Plugins 2.0 one-step Add: install, approve and enable in this workspace.
    /// When the policy holds the package for review, the person adding it is
    /// the reviewer, so the approval record is written first and the enable
    /// runs against it. Connector sign-ins are left for later: adding never
    /// asks for credentials.
    @discardableResult
    func add(
        _ package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        var context = policyContext
        if let record = try CapabilityApprovalGrant.pendingRecord(
            for: package,
            context: policyContext,
            approvedBy: "user",
            reviewNotes: "Added in Plugins."
        ) {
            let saved = try approvalStore.save(
                package: package,
                status: record.status,
                approvedBy: record.approvedBy,
                reviewNotes: record.reviewNotes,
                approvedAt: record.approvedAt
            )
            context.approvalRecords.append(saved)
        }
        return try enable(
            package,
            workspace: workspace,
            modelContext: modelContext,
            policyContext: context,
            source: "plugins_add",
            traceID: traceID
        )
    }

    /// Plugins 2.0 Update: re-runs Add with the library's definition, which
    /// rewrites the plugin's skills, connectors and tools and records the new
    /// version, then drops this workspace's activations of skills the plugin
    /// no longer ships. This visible step replaces the startup repair that
    /// rewrote definitions silently on every launch.
    @discardableResult
    func update(
        _ package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        let previousVersion = workspace.capabilityActivation.installedVersion(of: package.id)
        let result = try add(
            package,
            workspace: workspace,
            modelContext: modelContext,
            policyContext: policyContext,
            approvalStore: approvalStore,
            traceID: traceID
        )
        let current = Set(result.skillIDs.map(\.uuidString))
        let packageID = package.id
        let skillKind = CapabilityResourceComponentKind.skill.rawValue
        let stale = Set(try modelContext.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal }))
            .filter { $0.originPackageID == packageID && $0.originComponentKind == skillKind }
            .map(\.id.uuidString)
            .filter { !current.contains($0) })
        let pruned = WorkspaceCapabilityActivation.mutate(workspace) { state -> Bool in
            let before = state.globalSkillIDs.count
            state.globalSkillIDs.removeAll { stale.contains($0) }
            return state.globalSkillIDs.count != before
        }
        if pruned, !WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: workspace,
            modelContext: modelContext,
            auditFields: ["source": "plugins_update", "package_id": package.id]
        ) {
            throw CapabilityInstaller.InstallationError.persistenceFailed(packageID: package.id)
        }
        AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
            "source": "plugins_update",
            "package_id": package.id,
            "package_version": package.version,
            "previous_version": previousVersion ?? "",
            "workspace_id": workspace.id.uuidString,
            "pruned_skill_count": String(pruned ? stale.count : 0),
            "trace_id": traceID
        ])
        return result
    }

    /// Turns a package off in one workspace, leaving it installed.
    @discardableResult
    func disable(
        _ package: PluginPackage,
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        modelContext: ModelContext
    ) -> CapabilityActivationDisabler.Result {
        let result = CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: capabilities,
            modelContext: modelContext
        )
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
        return result
    }

    private func failureFields(
        package: PluginPackage,
        workspace: Workspace,
        source: String,
        traceID: String,
        sourceURL: URL? = nil,
        error: Error
    ) -> [String: String] {
        var fields = [
            "source": source,
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "error_type": String(describing: type(of: error))
        ]
        if let sourceURL {
            fields["source_json_path"] = sourceURL.path
        }
        return fields
    }
}
