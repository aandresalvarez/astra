import SwiftUI
import ASTRACore

struct CapabilityInstallSheetRouter: View {
    let package: PluginPackage
    let workspace: Workspace
    let policyContext: CapabilityCatalogPolicyContext
    let onDismiss: () -> Void
    let onInstalled: (PluginPackage) -> Void

    var body: some View {
        if GoogleWorkspaceCapability.usesGoogleWorkspaceOAuthSetup(package) {
            GoogleWorkspaceCapabilityInstallSheet(
                package: package,
                workspace: workspace,
                policyContext: policyContext,
                onDismiss: onDismiss,
                onInstalled: onInstalled
            )
        } else {
            PluginInstallSheet(
                package: package,
                workspace: workspace,
                policyContext: policyContext,
                onDismiss: onDismiss,
                onInstalled: onInstalled
            )
        }
    }
}
