import SwiftUI
import SwiftData
import ASTRACore

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    var focusPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onPackageFocusChanged: (String?) -> Void = { _ in }
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }
    var googleWorkspaceSetupState: GoogleWorkspaceSetupState?

    @Environment(\.modelContext) private var modelContext
    @Query private var googleAccounts: [GoogleOAuthAccountProfile]
    @State private var catalog = PluginCatalog()
    @State private var googleWorkspaceSetupError: String?
    @State private var isConnectingGoogleWorkspace = false
    @State private var revokeCandidate: GoogleOAuthAccountProfile?

    var body: some View {
        VStack(spacing: 0) {
            GoogleWorkspaceSetupPanel(
                state: effectiveGoogleWorkspaceSetupState,
                actions: googleWorkspaceSetupActions
            )
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            PluginCatalogView(
                workspace: workspace,
                catalog: catalog,
                focus: .all,
                presentation: .embedded,
                focusedPackageID: focusPackageID,
                onCatalogChanged: onCatalogChanged,
                onPackageFocusChanged: onPackageFocusChanged,
                onEditElement: onEditElement
            )
        }
        .alert("Google Workspace setup", isPresented: googleWorkspaceSetupErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(googleWorkspaceSetupError ?? "")
        }
        .confirmationDialog(
            "Revoke Google Workspace access?",
            isPresented: revokeConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                revokeGoogleWorkspaceAccess()
            }
            Button("Cancel", role: .cancel) {
                revokeCandidate = nil
            }
        } message: {
            Text("ASTRA will remove the local Google access and refresh tokens for this account.")
        }
    }

    private var effectiveGoogleWorkspaceSetupState: GoogleWorkspaceSetupState {
        googleWorkspaceSetupState ?? GoogleWorkspaceSetupStateFactory.make(accounts: googleAccounts)
    }

    private var selectedGoogleAccount: GoogleOAuthAccountProfile? {
        GoogleWorkspaceSetupStateFactory.selectedAccount(from: googleAccounts)
    }

    private var googleWorkspaceSetupActions: GoogleWorkspaceSetupPanelActions {
        GoogleWorkspaceSetupPanelActions(
            connect: { connectGoogleWorkspace() },
            upgradeScopes: { connectGoogleWorkspace() },
            reauthorize: { connectGoogleWorkspace() },
            reconnect: { connectGoogleWorkspace() },
            retryPreflight: { onCatalogChanged() },
            reviewApprovals: { onPackageFocusChanged("google-workspace") },
            revoke: selectedGoogleAccount.map { account in
                { revokeCandidate = account }
            }
        )
    }

    private var googleWorkspaceSetupErrorBinding: Binding<Bool> {
        Binding(
            get: { googleWorkspaceSetupError != nil },
            set: { if !$0 { googleWorkspaceSetupError = nil } }
        )
    }

    private var revokeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { revokeCandidate != nil },
            set: { if !$0 { revokeCandidate = nil } }
        )
    }

    private func connectGoogleWorkspace() {
        guard !isConnectingGoogleWorkspace else { return }
        isConnectingGoogleWorkspace = true
        Task { @MainActor in
            defer { isConnectingGoogleWorkspace = false }
            do {
                let configuration = try GoogleOAuthConfiguration.load()
                let service = GoogleOAuthAccountService(configuration: configuration)
                _ = try await service.connectAccount(
                    in: modelContext,
                    requestedScopes: effectiveGoogleWorkspaceSetupState.requiredScopes
                )
                onCatalogChanged()
            } catch {
                googleWorkspaceSetupError = error.localizedDescription
            }
        }
    }

    private func revokeGoogleWorkspaceAccess() {
        guard let account = revokeCandidate else { return }
        do {
            try GoogleOAuthCredentialVault().revoke(account)
            account.authState = .revoked
            account.revokedAt = Date()
            account.updatedAt = Date()
            try modelContext.save()
            onCatalogChanged()
        } catch {
            googleWorkspaceSetupError = error.localizedDescription
        }
        revokeCandidate = nil
    }
}
