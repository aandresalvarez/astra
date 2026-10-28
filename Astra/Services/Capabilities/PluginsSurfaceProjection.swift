import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// One presentation pass over already loaded catalog/policy/credential status.
/// Its detached resources live only for this render; searches never scan files
/// or read the credential store.
@MainActor
struct PluginsSurfaceProjection {
    let state: PluginsSurfaceState
    let rows: [String: PluginRow]
    let unusedAccounts: [Connector]

    static func make(workspace: Workspace, capabilities: WorkspaceCapabilities,
        catalogPackages: [PluginPackage], context: CapabilityCatalogPolicyContext,
        credentialReadiness: PluginCredentialReadiness, secretStore: SecretStore = KeychainSecretStore(), statuses: [String: HealthStatus],
        query: String, googleConnected: Bool = false,
        isRemovable: (PluginPackage) -> Bool) -> Self {
        let currentCapabilities = capabilities.snapshotForPresentation()
        let packages = CapabilityGalleryInventory.managementPackages(catalogPackages: catalogPackages,
            capabilities: currentCapabilities, workspace: workspace, policyContext: context)
        var rows: [String: PluginRow] = [:]
        var inputs: [PluginsSurfacePresentation.Input] = []
        for package in packages {
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities, secretStore: secretStore, credentialReadiness: credentialReadiness,
                projectedResources: PluginRuntimeProjection.project(workspace: workspace, packages: [package], definitions: catalogPackages))
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
            let listing = PluginsSurfacePresentation.listing(for: decision, isEnabled: packageState.isEnabled)
            var input = PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + packageState.missingConnectors.count
                    + PluginsSurfacePresentation.pendingSetupChecks(for: package, statuses: statuses)
                    + PluginsSurfacePresentation.pendingAccounts(for: package, googleAccountConnected: googleConnected).count,
                isVisible: listing.isVisible,
                isRemovable: isRemovable(package),
                blocker: listing.blocker,
                awaitsUpdate: packageState.awaitsUpdate
            )
            input.unavailableReason = PluginsSurfacePresentation.unavailableReason(for: package)
            input.origin = PluginSourceCoordinator.shared.origin(of: package)
            // Any drift an Update would settle: version, digest, components
            // or templates.
            input.needsUpdate = activation.map {
                PluginUpdateService.needsReconcile($0, to: package)
                    || !PluginTemplateSync.isInSync(package, in: workspace)
            } ?? false
            inputs.append(input)
            rows[package.id] = PluginRow(package: package, activation: activation, display: PluginsSurfacePresentation.makeState(
                [input], query: ""
            ).allRows.first ?? placeholderRow(package))
        }
        // An activation whose plugin the library no longer has is listed
        // too, so it can be removed (`CapabilityUninstaller.forgetMissing`).
        let libraryIDs = Set(catalogPackages.map(\.id))
        for input in PluginsSurfacePresentation.missingInputs(in: workspace, libraryIDs: libraryIDs, listedIDs: Set(rows.keys)) {
            inputs.append(input)
            rows[input.package.id] = PluginRow(package: input.package,
                activation: WorkspaceCapabilityActivation.activation(for: input.package.id, in: workspace),
                display: PluginsSurfacePresentation.makeState([input], query: "").allRows.first ?? placeholderRow(input.package))
        }
        let unusedAccounts = PluginsSurfacePresentation.unusedAccounts(
            in: workspace,
            workspaceConnectors: currentCapabilities.workspaceConnectors,
            sharedConnectors: currentCapabilities.enabledGlobalConnectors,
            listedPackages: inputs.filter(\.isVisible).map(\.package),
            query: query
        )
        return Self(state: PluginsSurfacePresentation.makeState(inputs, query: query), rows: rows, unusedAccounts: unusedAccounts)
    }

    private static func placeholderRow(_ package: PluginPackage) -> PluginsSurfaceRow {
        PluginsSurfaceRow(
            id: package.id, name: package.name, icon: package.icon, subtitle: "",
            pendingSteps: 0, isEnabled: false, isRemovable: false, verb: nil
        )
    }

}
