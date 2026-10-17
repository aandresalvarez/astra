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
        _ = try Self.addRoute(for: package)
        let context = try grantPendingApproval(for: package, policyContext: policyContext, approvalStore: approvalStore)
        return try enable(
            package,
            workspace: workspace,
            modelContext: modelContext,
            policyContext: context,
            source: "plugins_add",
            traceID: traceID
        )
    }

    /// The approval Add writes when the policy holds `package` for review:
    /// the person adding it is the reviewer. Returns the context to enable
    /// against. An install flow that connects an account first (OAuth) takes
    /// it the same way, so its enable isn't refused for want of approval.
    func grantPendingApproval(
        for package: PluginPackage,
        policyContext: CapabilityCatalogPolicyContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore()
    ) throws -> CapabilityCatalogPolicyContext {
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
        return context
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
