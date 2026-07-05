import SwiftUI
import SwiftData
import ASTRACore

struct GoogleWorkspaceCapabilityInstallSheet: View {
    let package: PluginPackage
    let workspace: Workspace
    let policyContext: CapabilityCatalogPolicyContext
    let onDismiss: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var googleAccounts: [GoogleOAuthAccountProfile]

    @State private var oauthClientID: String
    @State private var redirectURI: String
    @State private var useCustomOAuth: Bool
    @State private var setupError: String?
    @State private var installError: String?
    @State private var isConnecting = false
    @State private var configurationSaved = false
    @State private var revokeCandidate: GoogleOAuthAccountProfile?

    init(
        package: PluginPackage,
        workspace: Workspace,
        policyContext: CapabilityCatalogPolicyContext,
        onDismiss: @escaping () -> Void,
        onInstalled: @escaping (PluginPackage) -> Void
    ) {
        self.package = package
        self.workspace = workspace
        self.policyContext = policyContext
        self.onDismiss = onDismiss
        self.onInstalled = onInstalled

        let settings = GoogleOAuthConfigurationSettings.load()
        _oauthClientID = State(
            initialValue: settings.source == .custom
                ? settings.clientID
                : GoogleOAuthConfigurationSettings.storedCustomClientID()
        )
        _redirectURI = State(initialValue: settings.redirectURI)
        _useCustomOAuth = State(initialValue: settings.source != .managed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    oauthConfigurationSection
                    GoogleWorkspaceSetupPanel(state: setupState, actions: setupActions)
                    capabilityScopeSection
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 620, height: 640)
        .alert("Google Workspace setup", isPresented: setupErrorBinding) {
            Button("OK", role: .cancel) { setupError = nil }
        } message: {
            Text(setupError ?? "")
        }
        .alert("Capability could not be installed", isPresented: installErrorBinding) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CapabilityIconView(
                presentation: .make(for: package),
                size: 22,
                color: Stanford.lagunita,
                weight: .semibold
            )
            .frame(width: 44, height: 44)
            .background(Stanford.lagunita.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Enable \(package.name)")
                    .font(Stanford.heading(18))
                    .foregroundStyle(Stanford.black)
                Text(package.description)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(20)
    }

    private var oauthConfigurationSection: some View {
        GoogleWorkspaceOAuthConfigurationSection(
            useCustomOAuth: $useCustomOAuth,
            oauthClientID: $oauthClientID,
            redirectURI: $redirectURI,
            presentation: oauthSetupPresentation,
            configurationSaved: configurationSaved,
            hasManagedClient: hasManagedOAuthClient,
            onSaveCustom: saveCustomOAuthConfiguration,
            onUseManaged: useManagedOAuthConfiguration
        )
        .onChange(of: oauthClientID) { _, _ in
            configurationSaved = false
        }
        .onChange(of: redirectURI) { _, _ in
            configurationSaved = false
        }
        .onChange(of: useCustomOAuth) { _, _ in
            configurationSaved = false
        }
    }

    private var capabilityScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Remote MCP servers", systemImage: "server.rack")
                .font(Stanford.body(13).weight(.semibold))
                .foregroundStyle(Stanford.black)

            VStack(spacing: 0) {
                ForEach(Array(package.mcpServers.enumerated()), id: \.element.id) { index, server in
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(Stanford.ui(12, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName)
                                .font(Stanford.caption(12).weight(.semibold))
                                .foregroundStyle(Stanford.black)
                            Text(server.url?.host() ?? server.id)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)

                    if index < package.mcpServers.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(Stanford.fog.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: setupReady ? "checkmark.circle.fill" : "info.circle")
                    .font(Stanford.ui(12))
                Text(setupReady ? "Ready to enable" : "Connect Google Workspace first")
                    .font(Stanford.caption(11))
            }
            .foregroundStyle(setupReady ? Stanford.paloAltoGreen : Stanford.coolGrey)

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button("Enable") {
                installCapability()
            }
            .buttonStyle(.borderedProminent)
            .tint(Stanford.lagunita)
            .keyboardShortcut(.defaultAction)
            .disabled(!setupReady)
            .help(setupReady ? "Enable \(package.name)" : "Connect Google Workspace before enabling this capability.")
        }
        .padding(20)
    }

    private var setupState: GoogleWorkspaceSetupState {
        GoogleWorkspaceSetupStateFactory.make(accounts: googleAccounts)
    }

    private var oauthSetupPresentation: GoogleWorkspaceOAuthSetupPresentation {
        GoogleWorkspaceOAuthSetupPresentation.make(
            settings: currentOAuthSettings,
            managedClientAvailable: hasManagedOAuthClient
        )
    }

    private var currentOAuthSettings: GoogleOAuthConfigurationSettings {
        if useCustomOAuth {
            return GoogleOAuthConfigurationSettings(
                clientID: oauthClientID,
                redirectURI: redirectURI,
                source: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .custom
            )
        }
        let managedClientID = GoogleOAuthConfigurationSettings.managedClientID()
        return GoogleOAuthConfigurationSettings(
            clientID: managedClientID,
            redirectURI: redirectURI,
            source: managedClientID.isEmpty ? .missing : .managed
        )
    }

    private var hasManagedOAuthClient: Bool {
        !GoogleOAuthConfigurationSettings.managedClientID().isEmpty
    }

    private var setupReady: Bool {
        GoogleWorkspaceSetupPresentation.make(state: setupState).issues.isEmpty
    }

    private var selectedGoogleAccount: GoogleOAuthAccountProfile? {
        GoogleWorkspaceSetupStateFactory.selectedAccount(from: googleAccounts)
    }

    private var setupActions: GoogleWorkspaceSetupPanelActions {
        GoogleWorkspaceSetupPanelActions(
            connect: { connectGoogleWorkspace() },
            upgradeScopes: { connectGoogleWorkspace() },
            reauthorize: { connectGoogleWorkspace() },
            reconnect: { connectGoogleWorkspace() },
            retryPreflight: nil,
            reviewApprovals: nil,
            revoke: selectedGoogleAccount.map { account in
                { revokeCandidate = account }
            }
        )
    }

    private var setupErrorBinding: Binding<Bool> {
        Binding(
            get: { setupError != nil },
            set: { if !$0 { setupError = nil } }
        )
    }

    private var installErrorBinding: Binding<Bool> {
        Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )
    }

    private var revokeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { revokeCandidate != nil },
            set: { if !$0 { revokeCandidate = nil } }
        )
    }

    private func saveConfiguration() throws -> GoogleOAuthConfiguration {
        if useCustomOAuth {
            let settings = GoogleOAuthConfigurationSettings(
                clientID: oauthClientID,
                redirectURI: redirectURI,
                source: .custom
            )
            let configuration = try GoogleOAuthConfiguration.load(settings: settings)
            settings.saveCustom()
            return configuration
        }
        GoogleOAuthConfigurationSettings.preferManaged()
        return try GoogleOAuthConfiguration.load()
    }

    private func saveCustomOAuthConfiguration() {
        do {
            _ = try saveConfiguration()
            configurationSaved = true
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func useManagedOAuthConfiguration() {
        guard hasManagedOAuthClient else { return }
        GoogleOAuthConfigurationSettings.preferManaged()
        let settings = GoogleOAuthConfigurationSettings.load()
        redirectURI = settings.redirectURI
        useCustomOAuth = false
        configurationSaved = false
    }

    private func connectGoogleWorkspace() {
        guard !isConnecting else { return }
        isConnecting = true
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                let configuration = try saveConfiguration()
                configurationSaved = true
                let service = GoogleOAuthAccountService(configuration: configuration)
                _ = try await service.connectAccount(
                    in: modelContext,
                    requestedScopes: setupState.requiredScopes
                )
            } catch {
                setupError = error.localizedDescription
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
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: workspace, modelContext: modelContext)
        } catch {
            setupError = error.localizedDescription
        }
        revokeCandidate = nil
    }

    private func installCapability() {
        guard setupReady else {
            installError = "Connect Google Workspace before enabling this capability."
            return
        }
        do {
            _ = try saveConfiguration()
            try CapabilityCatalogActionService().enable(
                package,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: policyContext,
                source: "google_workspace_setup_sheet",
                traceID: AuditTrace.make("google-workspace-enable")
            )
            onInstalled(package)
        } catch {
            installError = error.localizedDescription
        }
    }
}
