import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
struct CapabilityCatalogActionService {
    let installer: CapabilityInstaller
    let uninstaller: CapabilityUninstaller

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
    ) {
        self.installer = CapabilityInstaller(library: library, appVersion: appVersion)
        self.uninstaller = CapabilityUninstaller(library: library)
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

    /// Imports a plugin file (a manifest or package JSON) into the library as
    /// a local draft. It is listed under Available afterwards and added like
    /// any other plugin; importing enables nothing.
    @discardableResult
    func importFile(
        at url: URL,
        workspace: Workspace,
        importer: CapabilityPackageImporter? = nil,
        traceID: String
    ) throws -> PluginPackage {
        let importer = importer ?? CapabilityPackageImporter(library: installer.library)
        let report = importer.validateFile(at: url)
        do {
            let result = try importer.importValidatedPackage(report)
            AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
                "source": "import_json",
                "trace_id": traceID,
                "package_id": result.package.id,
                "package_name": result.package.name,
                "package_version": result.package.version,
                "workspace_id": workspace.id.uuidString
            ])
            return result.package
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: CapabilityAudit.importJSONFailureFields(
                report: report,
                workspace: workspace,
                traceID: traceID,
                result: report.canInstall ? "import_failed" : "validation_blocked"
            ), level: .warning)
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
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
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
            configInputs: configInputs,
            baseURLOverrides: baseURLOverrides,
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
