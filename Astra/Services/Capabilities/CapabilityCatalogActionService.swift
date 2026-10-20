import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

struct CapabilityCatalogCreateActionResult {
    var package: PluginPackage
    var approvalRecordChanged: Bool
    var installedPackage: PluginPackage?
}

/// A plugin needs an account ASTRA has no sign-in flow for.
enum CapabilityAccountSetupError: Error, Equatable, LocalizedError {
    case unsupportedProvider(account: String, provider: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let account, let provider):
            let named = provider.map { " (\($0))" } ?? ""
            return "This plugin needs \(account)\(named), and ASTRA can't connect that kind of account yet."
        }
    }
}

@MainActor
struct CapabilityCatalogActionService {
    /// What Plugins Add does with a package.
    enum AddRoute: Equatable {
        /// Install, approve and enable in one step.
        case enable
        /// Open the install flow that connects the package's account first.
        case connectAccount
    }

    /// OAuth providers with a real sign-in flow (`CapabilityInstallSheetRouter`).
    static let supportedOAuthProviders: Set<String> = [GoogleWorkspaceCapability.connectorBinding]

    /// How Add handles `package`. A package that needs an account of a
    /// provider ASTRA can't sign in to is refused: the router's fallback
    /// sheet would enable it with no account, and it would read as ready
    /// though its setup never ran. An optional account neither routes nor
    /// refuses: the plugin works without it.
    static func addRoute(for package: PluginPackage) throws -> AddRoute {
        let accounts = package.setupRequirements.filter { $0.kind == .oauthAccount && $0.required }
        if let unsupported = accounts.first(where: { !supportedOAuthProviders.contains($0.provider ?? "") }) {
            throw CapabilityAccountSetupError.unsupportedProvider(account: unsupported.displayName, provider: unsupported.provider)
        }
        return accounts.isEmpty ? .enable : .connectAccount
    }

    let installer: CapabilityInstaller
    let creationService: CapabilityPackageCreationService
    let uninstaller: CapabilityUninstaller
    let library: CapabilityLibrary

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
    ) {
        self.installer = CapabilityInstaller(library: library, appVersion: appVersion)
        self.creationService = CapabilityPackageCreationService(library: library, appVersion: appVersion)
        self.uninstaller = CapabilityUninstaller(library: library)
        self.library = library
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
        traceID: String,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        pendingApproval: CapabilityApprovalRecord? = nil
    ) throws -> CapabilityInstaller.InstallationResult {
        do {
            // Every enable path (the legacy catalog's install sheets and
            // Configure included) refuses a required account ASTRA can't
            // sign in to, not only Plugins Add.
            _ = try Self.addRoute(for: package)
            let result = try installer.install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: allowCredentialUserInteraction,
                policyContext: policyContext,
                traceID: traceID, approvalStore: approvalStore, pendingApproval: pendingApproval
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

    /// Approves the draft an import staged over an approved plugin
    /// (`CapabilityLibrary.stage`) through the prepared file/receipt boundary.
    /// Reconciliation and approval either commit together or retain the draft
    /// and restore the previous installed bytes.
    func reviewStaged(id: String) throws -> PluginStagedReview {
        try PluginStagedReview.capture(id: id, library: library)
    }

    @discardableResult
    func approveStaged(
        _ review: PluginStagedReview,
        modelContext: ModelContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        approvedBy: String = "ASTRA local admin"
    ) throws -> PluginPackage {
        try PluginStagedApproval.approve(review, library: library, modelContext: modelContext,
            approvalStore: approvalStore, approvedBy: approvedBy)
    }

    /// Drops a staged draft: the approved copy stays what it was.
    func discardStaged(_ review: PluginStagedReview, modelContext: ModelContext) throws {
        try PluginStagedDiscard.discard(review, library: library, modelContext: modelContext)
    }

    /// Remove for a plugin the library no longer has a readable entry for.
    @discardableResult
    func forgetMissing(pluginID: String, modelContext: ModelContext) throws -> CapabilityUninstaller.RemovalResult {
        try uninstaller.forgetMissing(pluginID: pluginID, modelContext: modelContext)
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
        _ = try Self.addRoute(for: package)
        let stored = PluginInstallationTransaction.reviewedPackage(package)
        let pending = try CapabilityApprovalGrant.pendingRecord(for: stored, context: policyContext,
            approvedBy: "user", reviewNotes: "Added in Plugins.")
        var context = policyContext
        if let pending { context.approvalRecords.append(pending) }
        do {
            let result = try enable(stored, workspace: workspace, modelContext: modelContext,
                policyContext: context, source: "plugins_add", traceID: traceID,
                approvalStore: approvalStore, pendingApproval: pending)
            if let pending { auditAddedApproval(pending, workspace: workspace, traceID: traceID) }
            return result
        } catch {
            if let pending, let problem = error as? PluginOperationProblem,
               (try? PluginOperationCommit.read(problem.operationID, container: modelContext.container)) != nil,
               approvalStore.records().contains(pending) {
                auditAddedApproval(pending, workspace: workspace, traceID: traceID)
            }
            throw error
        }
    }

    private func auditAddedApproval(_ record: CapabilityApprovalRecord, workspace: Workspace, traceID: String) {
        AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: [
            "source": "plugins_add", "trace_id": traceID, "package_id": record.packageID,
            "package_version": record.packageVersion, "status": record.status.rawValue,
            "workspace_id": workspace.id.uuidString, "digest_prefix": String(record.sourceDigest.prefix(12))
        ])
    }


    /// The approval Add writes when the policy holds `package` for review:
    /// the person adding it is the reviewer. Returns the context to enable
    /// against. An install flow that connects an account first (OAuth) takes
    /// it the same way, so its enable isn't refused for want of approval.
    /// Audited like the catalog review's approval: the record is a durable
    /// permission change even when the enable after it never happens.
    func grantPendingApproval(
        for package: PluginPackage,
        workspace: Workspace,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        source: String,
        traceID: String
    ) throws -> CapabilityCatalogPolicyContext {
        var context = policyContext
        var fields = [
            "source": source,
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "status": CapabilityApprovalStatus.approved.rawValue,
            "workspace_id": workspace.id.uuidString
        ]
        do {
            guard let record = try CapabilityApprovalGrant.pendingRecord(
                for: package,
                context: policyContext,
                approvedBy: "user",
                reviewNotes: "Added in Plugins."
            ) else { return context }
            fields["digest_prefix"] = String(record.sourceDigest.prefix(12))
            let saved = try approvalStore.save(
                package: package,
                status: record.status,
                approvedBy: record.approvedBy,
                reviewNotes: record.reviewNotes,
                approvedAt: record.approvedAt
            )
            context.approvalRecords.append(saved)
            fields["status"] = saved.status.rawValue
            fields["digest_prefix"] = String(saved.sourceDigest.prefix(12))
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: fields)
            return context
        } catch {
            fields["result"] = "failed"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
    }

    /// Turns a package off in one workspace, leaving it installed and
    /// deleting nothing. A row standing for a standalone skill
    /// (`skill.<uuid>`) has no activation: a shared skill leaves this
    /// workspace's scope, and a workspace's own skill, which has no off state
    /// short of deleting it, is refused (`PluginsSurfacePresentation.offersTurnOff`).
    /// A saved disable is audited like Configure's (`capabilityDisabled`); a
    /// rolled-back one is audited by the disabler.
    @discardableResult
    func disable(
        _ package: PluginPackage,
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        modelContext: ModelContext,
        traceID: String = AuditTrace.make("capability-disable")
    ) -> CapabilityActivationDisabler.Result {
        guard PluginsSurfacePresentation.offersTurnOff(package) else {
            return CapabilityActivationDisabler.Result(packageID: package.id, persisted: false)
        }
        let result = CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: capabilities,
            modelContext: modelContext,
            keepingWorkspaceRows: CapabilityInstaller.syntheticSkillRowID(of: package) != nil
        )
        if result.persisted {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "plugins_turn_off",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString,
                "disabled_skills_count": String(result.disabledSkillIDs.count),
                "disabled_connectors_count": String(result.disabledConnectorIDs.count),
                "disabled_tools_count": String(result.disabledToolIDs.count),
                "removed_workspace_skills_count": String(result.removedWorkspaceSkillIDs.count),
                "removed_workspace_connectors_count": String(result.removedWorkspaceConnectorIDs.count),
                "enabled_capability_ids": CapabilityAudit.compactNames(WorkspaceCapabilityActivation.state(of: workspace).capabilityIDs)
            ])
        }
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
        return result
    }

    /// The row's Update: brings every workspace's activations of `package`
    /// to its definition in the library, releasing what it dropped. Only
    /// the definition read back from the library is reconciled against,
    /// never the row's own copy: with none readable, nothing changes.
    func update(_ package: PluginPackage, modelContext: ModelContext) throws {
        guard let definition = library.installedPackages().first(where: { $0.id == package.id }) else {
            throw PluginUpdateService.UpdateError.definitionUnreadable(plugin: package.name)
        }
        // Refused for every workspace if one with an activation of it would
        // refuse this definition, as an import is, before anything changes.
        if let refusal = PluginUpdateService.refusals(for: definition, modelContext: modelContext).first {
            throw refusal
        }
        try PluginUpdateService.reconcileAll(modelContext: modelContext, packages: [definition], mode: .release)
        CapabilityCatalogPersistenceEvents.post(.global)
    }

    /// A plugin skill's setting in one workspace (secret ones to the Keychain).
    func setSetting(
        _ key: String,
        to value: String,
        of skill: PluginSkill,
        package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext
    ) throws {
        try PluginOperations.setSetting(key, to: value, of: skill, pluginID: package.id, in: workspace, modelContext: modelContext)
    }

    /// A new account for a connector component, bound in this workspace.
    @discardableResult
    func addAccount(
        for connector: PluginConnector,
        of package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Connector {
        let account = try PluginOperations.addAccount(for: connector, of: package, in: workspace, modelContext: modelContext)
        return account
    }

    func makeDefault(
        _ account: Connector,
        componentID: String,
        package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext
    ) throws {
        try PluginOperations.makeDefault(account, componentID: componentID, pluginID: package.id, in: workspace, modelContext: modelContext)
    }

    /// Deletes an account in every workspace, with its credentials.
    func deleteAccount(_ account: Connector, modelContext: ModelContext) throws {
        try PluginOperations.deleteAccount(account, modelContext: modelContext)
        CapabilityCatalogPersistenceEvents.post(.global)
    }

    /// Turns a shared account on in this workspace: the step an added
    /// plugin's account needs when it exists, shared, but is off here. False
    /// when the save fails; the activation is then undone. Audited like the
    /// Configure toggle (`connectorUpdated`): it grants the workspace the
    /// account's credentials.
    @discardableResult
    func activateSharedConnector(
        _ connector: Connector,
        workspace: Workspace,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = CapabilityPersistence.defaultPersist
    ) -> Bool {
        guard connector.isGlobal else { return false }
        guard !WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs.contains(connector.id.uuidString) else {
            return true
        }
        var fields = [
            "connector_id": connector.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "source": "plugins_turn_on"
        ]
        CapabilitySharing.enableShared(connector, in: workspace)
        guard persist(workspace, modelContext) else {
            CapabilitySharing.disableShared(connector, in: workspace)
            fields["enabled_global"] = "false"
            fields["result"] = "failed"
            AppLogger.audit(.connectorUpdated, category: "Capabilities", fields: fields, level: .error)
            return false
        }
        fields["enabled_global"] = String(
            WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs.contains(connector.id.uuidString)
        )
        AppLogger.audit(.connectorUpdated, category: "Capabilities", fields: fields)
        PluginStateMirrors.exportAfterSave(workspace: workspace, accounts: [connector], modelContext: modelContext)
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
        return true
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
