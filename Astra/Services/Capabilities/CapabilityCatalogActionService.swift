import Foundation
import SwiftData
import ASTRACore

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
        policyContext: CapabilityCatalogPolicyContext,
        source: String,
        traceID: String
    ) throws -> CapabilityInstaller.InstallationResult {
        do {
            return try installer.install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                policyContext: policyContext,
                traceID: traceID
            )
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
                policyContext: policyContext,
                traceID: traceID
            )
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
