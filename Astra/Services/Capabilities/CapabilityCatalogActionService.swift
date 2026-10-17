import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

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

    /// Brings every workspace's activations up to the definitions in the
    /// library (the Update verb, after a reconcile that failed earlier).
    func update(modelContext: ModelContext) throws {
        try PluginUpdateService.reconcileAll(modelContext: modelContext, packages: library.installedPackages())
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
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
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
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
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
        CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
    }

    /// Deletes an account in every workspace, with its credentials.
    func deleteAccount(_ account: Connector, modelContext: ModelContext) throws {
        try PluginOperations.deleteAccount(account, modelContext: modelContext)
        CapabilityCatalogPersistenceEvents.post(.global)
    }

    /// Imports a validated plugin file. A newer version of an installed
    /// plugin is an Update for every workspace (see
    /// `CapabilityPackageImporter.importValidatedPackage`).
    @discardableResult
    func importPlugin(
        _ report: CapabilityPackageValidationReport,
        workspace: Workspace,
        modelContext: ModelContext,
        traceID: String
    ) throws -> CapabilityPackageImportResult {
        guard report.canInstall else {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: CapabilityAudit.importJSONFailureFields(
                report: report, workspace: workspace, traceID: traceID, result: "validation_blocked"
            ), level: .warning)
            throw CapabilityPackageImportError(report: report)
        }
        do {
            let result = try CapabilityPackageImporter(library: library).importValidatedPackage(report, modelContext: modelContext)
            AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
                "source": "import_json",
                "trace_id": traceID,
                "package_id": result.package.id,
                "package_name": result.package.name,
                "package_version": result.package.version,
                "workspace_id": workspace.id.uuidString
            ])
            return result
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: CapabilityAudit.importJSONFailureFields(
                report: report, workspace: workspace, traceID: traceID, result: "import_failed",
                errorType: String(describing: type(of: error))
            ), level: .error)
            throw error
        }
    }

    /// An admin's catalog review of one version (digest) of a plugin.
    func setApprovalStatus(
        _ status: CapabilityApprovalStatus,
        for package: PluginPackage,
        workspace: Workspace,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore()
    ) throws {
        let traceID = AuditTrace.make("capability-approval")
        do {
            let record = try approvalStore.save(
                package: package,
                status: status,
                approvedBy: "ASTRA local admin",
                reviewNotes: "Updated from the Plugins review controls."
            )
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: [
                "source": "plugins_review",
                "trace_id": traceID,
                "package_id": package.id,
                "package_version": package.version,
                "status": record.status.rawValue,
                "workspace_id": workspace.id.uuidString,
                "digest_prefix": String(record.sourceDigest.prefix(12))
            ])
        } catch {
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: [
                "source": "plugins_review",
                "trace_id": traceID,
                "package_id": package.id,
                "status": status.rawValue,
                "result": "failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            throw error
        }
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
