import SwiftUI
import SwiftData
import AppKit
import ASTRAModels
import ASTRAPersistence

struct ConnectorsManagerView: View {
    var workspace: Workspace
    var onManageCapabilities: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedConnector: Connector?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connectors")
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let onManageCapabilities {
                    Button { onManageCapabilities() } label: {
                        Label("Manage Capabilities", systemImage: "square.grid.2x2")
                    }
                    .help("Open Manage Capabilities")
                }
                Button { createConnector() } label: {
                    Label("New", systemImage: "plus")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                // List
                List(selection: $selectedConnector) {
                    ForEach(workspace.connectors.sorted(by: { $0.name < $1.name })) { connector in
                        connectorRow(connector)
                            .tag(connector)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                .background(Stanford.fog)

                Divider()

                // Editor
                if let connector = selectedConnector {
                    ConnectorEditorView(connector: connector, workspace: workspace, onDelete: {
                        deleteConnector(connector)
                    }, onDuplicate: { copy in
                        selectedConnector = copy
                    })
                } else {
                    ContentUnavailableView(
                        "Select a Connector",
                        systemImage: "network",
                        description: Text("Select a connector to edit or click + to create one.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 660, height: 500)
        .onAppear {
            if selectedConnector == nil, let first = workspace.connectors.first {
                selectedConnector = first
            }
        }
    }

    private func connectorRow(_ connector: Connector) -> some View {
        HStack(spacing: 8) {
            CapabilityLeadingIcon(
                systemImage: connector.icon,
                brand: BrandMark.resolve(id: connector.serviceType, name: connector.name),
                pointSize: 16
            )
            .foregroundStyle(.secondary)
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name.isEmpty ? "Untitled" : connector.name)
                    .font(Stanford.body(15))
                Text(rowSubtitle(connector))
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(rowSubtitle(connector))
            }
        }
    }

    /// Lead the subtitle with the recognizable service noun (GitHub, Jira, …),
    /// then the host/scoping metadata from `displaySummary` (P2a).
    private func rowSubtitle(_ connector: Connector) -> String {
        let label = ConnectorEditorView.serviceLabel(connector.serviceType)
        let summary = connector.displaySummary
        guard !summary.isEmpty, summary != connector.serviceType else { return label }
        return "\(label) · \(summary)"
    }

    private func createConnector() {
        let connector = Connector(name: "New Connector")
        connector.workspace = workspace
        modelContext.insert(connector)
        selectedConnector = connector
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorCreated, category: "UI", fields: [
            "connector_id": connector.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteConnector(_ connector: Connector) {
        if selectedConnector?.id == connector.id {
            selectedConnector = nil
        }
        connector.cleanupKeychain()
        modelContext.delete(connector)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

// MARK: - Connector Editor

/// A staged destructive action awaiting explicit confirmation. One piece of
/// state plus one `.confirmationDialog` serves every delete site in the editor,
/// so each dialog can name exactly what it will remove and run the deletion
/// only on an explicit second tap.
private struct PendingConnectorDeletion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void
}

struct ConnectorCredentialSaveFailurePresentation: Equatable {
    let key: String
    let message: String
    let actionTitle: String
    let actionSystemImage: String

    static func keychainSaveFailed(key: String) -> ConnectorCredentialSaveFailurePresentation {
        ConnectorCredentialSaveFailurePresentation(
            key: key,
            message: "Could not save \(key) to Keychain. Allow ASTRA to access its Keychain item, then retry.",
            actionTitle: "Allow & Save",
            actionSystemImage: MacOSPermissionKind.keychain.systemImage
        )
    }
}

private enum PendingConnectorCredentialSaveContext: Equatable {
    case newCredential
    case replacement(key: String)
}

struct ConnectorEditorView: View {
    @Bindable var connector: Connector
    var workspace: Workspace?
    let onDelete: () -> Void
    var onDuplicate: ((Connector) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var newCredKey = ""
    @State private var newCredValue = ""
    @State private var newConfigKey = ""
    @State private var newConfigValue = ""
    @State private var showSecrets = false
    @State private var isAddingCredential = false
    @State private var editingCredentialKey: String?
    @State private var replacementCredentialValue = ""
    @State private var credentialSaveError: ConnectorCredentialSaveFailurePresentation?
    @State private var pendingCredentialSaveContext: PendingConnectorCredentialSaveContext?
    @State private var newListItem = ""
    @State private var testResult: (Bool, String)?
    @State private var isTesting = false
    @State private var oauthDeviceCode: MicrosoftDeviceCodeResponse?
    @State private var oauthStatus = ""
    @State private var isOAuthSigningIn = false
    @State private var oauthSignInTask: Task<Void, Never>?
    @State private var oauthSignInGeneration = UUID()
    @State private var pendingDeletion: PendingConnectorDeletion?
    @FocusState private var isNameFocused: Bool

    private static let secretPatterns = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH"]

    private static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return secretPatterns.contains { upper.contains($0) }
    }

    private static func isListKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.contains("PROJECTS") || upper.contains("REPOS") ||
               upper.contains("CHANNELS") || upper.contains("TAGS") ||
               upper.contains("LABELS") || upper.contains("TEAMS") ||
               upper.contains("SCHEMAS") || upper.contains("SPACES")
    }

    private var missingCredentialKeys: [String] {
        connector.missingCredentialKeys()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Identity
                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: $connector.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                        TextField("Description", text: $connector.connectorDescription)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 12) {
                            Picker("Type", selection: $connector.serviceType) {
                                ForEach(["jira", "github", "slack", "database", "rest_api", "confluence", "redcap", "stanford_outlook_mail", "custom"], id: \.self) { t in
                                    Text(Self.serviceLabel(t)).tag(t)
                                }
                            }
                            .frame(width: 200)

                            Picker("Auth", selection: $connector.authMethod) {
                                ForEach(Self.authMethods(for: connector.serviceType), id: \.self) { a in
                                    Text(a.replacingOccurrences(of: "_", with: " ").capitalized).tag(a)
                                }
                            }
                            .frame(width: 180)
                        }

                        TextField("Base URL", text: $connector.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(14, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }

                // Test Connection — placed prominently after Identity
                GroupBox {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(
                            get: { connector.testHTTPMethod.isEmpty ? "GET" : connector.testHTTPMethod },
                            set: { connector.testHTTPMethod = $0; connector.updatedAt = Date() }
                        )) {
                            Text("GET").tag("GET")
                            Text("POST").tag("POST")
                            Text("HEAD").tag("HEAD")
                            Text("PUT").tag("PUT")
                        }
                        .labelsHidden()
                        .fixedSize()
                        .font(Stanford.ui(12, design: .monospaced))

                        Button {
                            let traceID = AuditTrace.make("connector-test")
                            AppLogger.breadcrumb(action: "test_connector_clicked", category: "Keychain", traceID: traceID, fields: [
                                "source": "configure_test_button",
                                "connector_id": connector.id.uuidString,
                                "connector_name": connector.name,
                                "service_type": connector.serviceType,
                                "workspace_id": workspace?.id.uuidString ?? "none"
                            ])
                            isTesting = true
                            testResult = nil
                            Task {
                                let result = await connector.testConnection(
                                    source: "configure_test_button",
                                    workspaceID: workspace?.id,
                                    traceID: traceID
                                )
                                await MainActor.run {
                                    testResult = result
                                    isTesting = false
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle")
                                        .font(Stanford.ui(14))
                                }
                                Text(isTesting ? "Testing..." : "Test Connection")
                                    .font(Stanford.body(14))
                                    .fontWeight(.medium)
                            }
                        }
                        .disabled(
                            isTesting ||
                            connector.baseURL.isEmpty ||
                            (connector.isStanfordOutlookMail
                                ? !connector.hasOutlookRefreshToken
                                : (connector.authMethod != "none" && connector.credentialKeys.isEmpty))
                        )
                        .buttonStyle(.borderedProminent)
                        .tint(Stanford.paloAltoGreen)

                        if let result = testResult {
                            HStack(spacing: 5) {
                                Image(systemName: result.0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(Stanford.ui(15))
                                    .foregroundStyle(result.0 ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                                Text(result.1)
                                    .font(Stanford.caption(13))
                                    .foregroundStyle(result.0 ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                            }
                        } else if !isTesting {
                            Text(missingCredentialKeys.isEmpty
                                 ? "Verify credentials and connectivity"
                                 : "Missing Keychain value: \(missingCredentialKeys.joined(separator: ", "))")
                                .font(Stanford.caption(13))
                                .foregroundStyle(missingCredentialKeys.isEmpty ? Color.secondary : Stanford.poppy)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Connectivity", systemImage: "network")
                }

                if connector.isStanfordOutlookMail {
                    outlookMailOAuthSection
                }

                // Configuration (non-secret)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Non-secret parameters visible in the UI. Used for scoping (projects, repos, channels).")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)

                        ForEach(Array(connector.configKeys.enumerated()), id: \.offset) { idx, key in
                            if idx < connector.configValues.count {
                                if idx > 0 {
                                    Divider().opacity(0.5)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key)
                                        .font(Stanford.ui(13, design: .monospaced))
                                        .fontWeight(.medium)

                                    if Self.isListKey(key) {
                                        let items = connector.configValues[idx]
                                            .split(separator: ",")
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }

                                        FlowLayout(spacing: 5) {
                                            ForEach(items, id: \.self) { item in
                                                HStack(spacing: 4) {
                                                    Text(item)
                                                        .font(Stanford.ui(12, design: .monospaced))
                                                    Button {
                                                        pendingDeletion = PendingConnectorDeletion(
                                                            title: "Remove “\(item)”?",
                                                            message: "Remove “\(item)” from \(key) on \(connectorDisplayName)?",
                                                            confirmTitle: "Remove"
                                                        ) {
                                                            guard idx < connector.configValues.count else { return }
                                                            let updated = items.filter { $0 != item }.joined(separator: ",")
                                                            connector.configValues[idx] = updated
                                                            connector.updatedAt = Date()
                                                        }
                                                    } label: {
                                                        Image(systemName: "xmark")
                                                            .font(Stanford.ui(10, weight: .bold))
                                                            .foregroundStyle(Stanford.coolGrey)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Stanford.lagunita.opacity(0.1))
                                                .foregroundStyle(Stanford.lagunita)
                                                .clipShape(Capsule())
                                            }
                                        }

                                        HStack(spacing: 6) {
                                            TextField("Add item", text: $newListItem)
                                                .textFieldStyle(.roundedBorder)
                                                .font(Stanford.ui(13, design: .monospaced))
                                                .onSubmit { addListItem(at: idx) }
                                            Button("Add") { addListItem(at: idx) }
                                                .disabled(newListItem.trimmingCharacters(in: .whitespaces).isEmpty)
                                        }
                                    } else {
                                        TextField("value", text: Binding(
                                            get: {
                                                guard idx < connector.configValues.count else { return "" }
                                                return connector.configValues[idx]
                                            },
                                            set: {
                                                guard idx < connector.configValues.count else { return }
                                                connector.configValues[idx] = $0
                                                connector.updatedAt = Date()
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(Stanford.ui(13, design: .monospaced))
                                    }

                                    HStack {
                                        Spacer()
                                        Button {
                                            pendingDeletion = PendingConnectorDeletion(
                                                title: "Remove “\(key)”?",
                                                message: "Remove the \(key) parameter from \(connectorDisplayName)? This clears its value.",
                                                confirmTitle: "Remove"
                                            ) {
                                                guard idx < connector.configKeys.count,
                                                      idx < connector.configValues.count else { return }
                                                connector.configKeys.remove(at: idx)
                                                connector.configValues.remove(at: idx)
                                                connector.updatedAt = Date()
                                            }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(11))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("KEY", text: $newConfigKey)
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.ui(13, design: .monospaced))
                                .frame(width: 140)
                            TextField("value", text: $newConfigValue)
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.ui(13, design: .monospaced))
                                .onSubmit { addConfig() }
                            Button("Add parameter") { addConfig() }
                                .disabled(newConfigKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Configuration", systemImage: "slider.horizontal.3")
                }

                // Secrets (credentials — stored in Keychain)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(Stanford.ui(11))
                                .foregroundStyle(Stanford.paloAltoGreen)
                            Text("Stored securely in macOS Keychain. Never shown in prompts or logs.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                        }
                        if let credentialSaveError {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    credentialSaveErrorLabel(credentialSaveError)
                                    retryCredentialSaveButton(credentialSaveError)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    credentialSaveErrorLabel(credentialSaveError)
                                    retryCredentialSaveButton(credentialSaveError)
                                }
                            }
                        }

                        if !connector.credentialKeys.isEmpty {
                            VStack(spacing: 4) {
                                // Identity is the position, not the key string: legacy data can
                                // carry duplicate keys, and deriving the index via firstIndex(of:)
                                // would then replace/remove the wrong secret.
                                ForEach(Array(connector.credentialKeys.enumerated()), id: \.offset) { idx, key in
                                    if idx > 0 {
                                        Divider().opacity(0.5)
                                    }
                                    HStack(spacing: 8) {
                                        Text(key)
                                            .font(Stanford.ui(13, design: .monospaced))
                                            .fontWeight(.medium)
                                            .frame(minWidth: 100, alignment: .leading)

                                        let inKeychain = KeychainService.exists(key: key, connector: connector)

                                        if showSecrets {
                                            let value = KeychainService.load(key: key, connector: connector)
                                                ?? (idx < connector.credentialValues.count ? connector.credentialValues[idx] : "")
                                            Text(value.isEmpty ? "(empty)" : value)
                                                .font(Stanford.ui(13, design: .monospaced))
                                                .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                                                .lineLimit(1)
                                        } else {
                                            HStack(spacing: 4) {
                                                Text(String(repeating: "\u{2022}", count: 12))
                                                    .font(Stanford.ui(13))
                                                    .foregroundStyle(.secondary)
                                                // P2: the header carries the count for stored secrets;
                                                // only flag the exceptional row that still needs a value.
                                                if !inKeychain {
                                                    Image(systemName: "exclamationmark.triangle")
                                                        .font(Stanford.ui(10))
                                                        .foregroundStyle(Stanford.poppy)
                                                        .help("Not yet in Keychain — re-enter value")
                                                }
                                            }
                                        }

                                        Spacer()

                                        if editingCredentialKey == key {
                                            SecureField("value", text: $replacementCredentialValue)
                                                .textFieldStyle(.roundedBorder)
                                                .font(Stanford.ui(12, design: .monospaced))
                                                .frame(maxWidth: 220)
                                                .onSubmit { saveCredentialReplacement(for: key) }

                                            Button("Save") {
                                                saveCredentialReplacement(for: key)
                                            }
                                            .font(Stanford.caption(12))
                                            .disabled(replacementCredentialValue.isEmpty)

                                            Button("Cancel") {
                                                cancelCredentialReplacement()
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.plain)
                                            .foregroundStyle(Stanford.coolGrey)
                                        } else {
                                            Button(inKeychain ? "Replace" : "Set Value") {
                                                editingCredentialKey = key
                                                replacementCredentialValue = ""
                                                credentialSaveError = nil
                                                pendingCredentialSaveContext = nil
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button {
                                                pendingDeletion = PendingConnectorDeletion(
                                                    title: "Remove secret “\(key)”?",
                                                    message: "Remove the \(key) secret from \(connectorDisplayName)? This deletes its stored Keychain value.",
                                                    confirmTitle: "Remove Secret"
                                                ) {
                                                    connector.removeCredential(at: idx)
                                                }
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(Stanford.ui(12))
                                                    .foregroundStyle(Stanford.coolGrey)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        if isAddingCredential {
                            HStack(spacing: 6) {
                                TextField("KEY", text: $newCredKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Stanford.ui(13, design: .monospaced))
                                    .frame(width: 140)
                                SecureField("value", text: $newCredValue)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Stanford.ui(13, design: .monospaced))
                                    .onSubmit { addCredential() }
                                Button("Store secret") { addCredential() }
                                    .disabled(newCredKey.trimmingCharacters(in: .whitespaces).isEmpty || newCredValue.isEmpty)
                                Button("Cancel") {
                                    cancelCredentialEntry()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Stanford.coolGrey)
                            }
                        } else {
                            Button {
                                isAddingCredential = true
                                credentialSaveError = nil
                                pendingCredentialSaveContext = nil
                            } label: {
                                Label("New secret", systemImage: "plus.circle")
                                    .font(Stanford.body(13))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Label("Secrets", systemImage: "key")
                        Spacer()
                        if !connector.credentialKeys.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill")
                                    .font(Stanford.ui(10))
                                    .foregroundStyle(Stanford.paloAltoGreen)
                                Text("\(connector.credentialKeys.count)")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            showSecrets.toggle()
                        } label: {
                            Image(systemName: showSecrets ? "eye.slash" : "eye")
                                .font(Stanford.ui(12))
                                .foregroundStyle(Stanford.coolGrey)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Sharing
                GroupBox("Sharing") {
                    if connector.isGlobal {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(
                                get: {
                                    guard let workspace else { return false }
                                    return workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString)
                                },
                                set: { enabled in
                                    guard let workspace else { return }
                                    if enabled {
                                        CapabilitySharing.enableShared(connector, in: workspace)
                                    } else {
                                        CapabilitySharing.disableShared(connector, in: workspace)
                                    }
                                    saveSharingChange()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Enabled in this workspace")
                                        .font(Stanford.body(14))
                                    Text("The shared connector stays installed for other workspaces.")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(workspace == nil)

                            Button {
                                duplicateForWorkspace()
                            } label: {
                                Label("Duplicate for this workspace", systemImage: "doc.on.doc")
                                    .font(Stanford.body(13))
                            }
                            .buttonStyle(.bordered)
                            .disabled(workspace == nil)
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { connector.isGlobal },
                            set: { newValue in
                                if newValue {
                                    CapabilitySharing.promoteToShared(connector, in: workspace)
                                }
                                saveSharingChange()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shared across all workspaces")
                                    .font(Stanford.body(14))
                                Text("Enable this connector in any workspace's plug-ins panel")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Notes
                GroupBox("Notes") {
                    TextEditor(text: $connector.notes)
                        .font(Stanford.ui(14))
                        .frame(minHeight: 40, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        pendingDeletion = PendingConnectorDeletion(
                            title: "Delete \(connectorDisplayName)?",
                            message: "Delete the connector \(connectorDisplayName)? This removes its configuration and any stored Keychain secrets. This cannot be undone.",
                            confirmTitle: "Delete Connector"
                        ) {
                            cancelOutlookSignIn()
                            onDelete()
                        }
                    } label: {
                        Label("Delete Connector", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .onAppear {
            if connector.name == "New Connector" {
                isNameFocused = true
            }
            normalizeAuthMethodForCurrentService()
        }
        .onChange(of: connector.serviceType) { _, newType in
            applyServiceDefaults(for: newType)
        }
        .onDisappear {
            cancelOutlookSignIn()
            connector.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(
                workspace: workspace ?? connector.workspace,
                modelContext: modelContext
            )
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { presented in if !presented { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.confirmTitle, role: .destructive) {
                deletion.perform()
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    private var connectorDisplayName: String {
        connector.name.isEmpty ? "this connector" : "“\(connector.name)”"
    }

    private var outlookMailOAuthSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Each account/domain is configured as a separate connector instance. Sign-in opens Microsoft device login, where Stanford or SHC handles Duo.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Email address", text: configBinding(StanfordOutlookMail.emailKey))
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.ui(13, design: .monospaced))

                    TextField("Tenant domain (stanford.edu or stanfordhealthcare.org)", text: configBinding(StanfordOutlookMail.tenantDomainKey))
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))

                    TextField("Microsoft Entra client ID", text: configBinding(StanfordOutlookMail.clientIDKey))
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.ui(13, design: .monospaced))
                }

                HStack(spacing: 8) {
                    Label(
                        connector.hasOutlookRefreshToken ? "Signed in" : "Not signed in",
                        systemImage: connector.hasOutlookRefreshToken ? "checkmark.shield.fill" : "person.crop.circle.badge.exclamationmark"
                    )
                    .font(Stanford.caption(12))
                    .foregroundStyle(connector.hasOutlookRefreshToken ? Stanford.paloAltoGreen : Stanford.poppy)

                    if !connector.outlookDisplayName.isEmpty {
                        Text(connector.outlookDisplayName)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if let oauthDeviceCode {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Code")
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                            Text(oauthDeviceCode.userCode)
                                .font(Stanford.mono(16).weight(.semibold))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(oauthDeviceCode.userCode, forType: .string)
                            }
                            .controlSize(.small)
                        }

                        Text(oauthDeviceCode.message)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Stanford.lagunita.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !oauthStatus.isEmpty {
                    Text(oauthStatus)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        startOutlookSignIn()
                    } label: {
                        if isOAuthSigningIn {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for Sign-In")
                            }
                        } else {
                            Label(connector.hasOutlookRefreshToken ? "Reconnect" : "Connect", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .disabled(isOAuthSigningIn || connector.outlookClientID.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(Stanford.lagunita)

                    Button {
                        Task { await testOutlookConnection() }
                    } label: {
                        Label("Test", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(!connector.hasOutlookRefreshToken || isTesting)

                    Button {
                        if isOAuthSigningIn {
                            cancelOutlookSignIn(status: "Sign-in cancelled.")
                        } else {
                            signOutOutlook()
                        }
                    } label: {
                        Label(isOAuthSigningIn ? "Cancel" : "Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(!connector.hasOutlookRefreshToken && !isOAuthSigningIn)

                    Spacer()

                    Button {
                        duplicateOutlookAccount()
                    } label: {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                    .disabled(workspace == nil)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Stanford Microsoft 365", systemImage: "envelope.badge.shield.half.filled")
        }
    }

    private func configBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: {
                let value = connector.configValue(key)
                return value.isEmpty ? defaultValue : value
            },
            set: { newValue in
                connector.setConfigValue(key, value: newValue)
                testResult = nil
            }
        )
    }

    private func startOutlookSignIn() {
        connector.applyStanfordOutlookDefaults(defaultTenant: false)
        cancelOutlookSignIn()
        let generation = UUID()
        oauthSignInGeneration = generation
        oauthDeviceCode = nil
        oauthStatus = "Requesting Microsoft sign-in code..."
        isOAuthSigningIn = true
        testResult = nil

        oauthSignInTask = Task {
            do {
                let auth = StanfordOutlookMailAuthService()
                let deviceCode = try await auth.startDeviceAuthorization(connector: connector)
                await MainActor.run {
                    guard oauthSignInGeneration == generation else { return }
                    oauthDeviceCode = deviceCode
                    oauthStatus = "A browser has opened. Complete Microsoft/Stanford sign-in, including Duo, then ASTRA will finish automatically."
                    if let url = URL(string: deviceCode.verificationUri) {
                        NSWorkspace.shared.open(url)
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deviceCode.userCode, forType: .string)
                }
                let token = try await auth.pollForToken(connector: connector, deviceCode: deviceCode)
                try Task.checkCancellation()
                let savedToken = await MainActor.run {
                    guard oauthSignInGeneration == generation else { return false }
                    return auth.saveTokenResponse(token, connector: connector, allowUserInteraction: true)
                }
                guard savedToken else {
                    await MainActor.run {
                        guard oauthSignInGeneration == generation else { return }
                        oauthStatus = "Microsoft sign-in completed, but ASTRA could not save the OAuth tokens to Keychain. Allow ASTRA to access its Keychain item, then sign in again."
                        testResult = (false, oauthStatus)
                        isOAuthSigningIn = false
                        oauthSignInTask = nil
                    }
                    return
                }
                let me = try await StanfordOutlookMailGraphService().testConnection(connector: connector)
                await MainActor.run {
                    guard oauthSignInGeneration == generation else { return }
                    let identity = me.mail ?? me.userPrincipalName ?? connector.outlookEmail
                    oauthStatus = identity.isEmpty ? "Connected to Microsoft Graph." : "Connected as \(identity)."
                    testResult = (true, oauthStatus)
                    oauthDeviceCode = nil
                    isOAuthSigningIn = false
                    oauthSignInTask = nil
                    saveSharingChange()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard oauthSignInGeneration == generation else { return }
                    oauthDeviceCode = nil
                    oauthStatus = "Sign-in cancelled."
                    isOAuthSigningIn = false
                    oauthSignInTask = nil
                }
            } catch {
                await MainActor.run {
                    guard oauthSignInGeneration == generation else { return }
                    oauthStatus = error.localizedDescription
                    testResult = (false, error.localizedDescription)
                    isOAuthSigningIn = false
                    oauthSignInTask = nil
                }
            }
        }
    }

    private func cancelOutlookSignIn(status: String? = nil) {
        oauthSignInGeneration = UUID()
        oauthSignInTask?.cancel()
        oauthSignInTask = nil
        oauthDeviceCode = nil
        isOAuthSigningIn = false
        if let status {
            oauthStatus = status
        }
    }

    private func testOutlookConnection() async {
        let traceID = AuditTrace.make("connector-test")
        AppLogger.breadcrumb(action: "test_connector_clicked", category: "Keychain", traceID: traceID, fields: [
            "source": "configure_test_button",
            "connector_id": connector.id.uuidString,
            "connector_name": connector.name,
            "service_type": connector.serviceType,
            "workspace_id": workspace?.id.uuidString ?? "none"
        ])
        await MainActor.run {
            isTesting = true
            testResult = nil
        }
        let result = await connector.testConnection(
            source: "configure_test_button",
            workspaceID: workspace?.id,
            traceID: traceID
        )
        await MainActor.run {
            testResult = result
            oauthStatus = result.1
            isTesting = false
            if result.0 {
                saveSharingChange()
            }
        }
    }

    private func signOutOutlook() {
        cancelOutlookSignIn()
        connector.clearOutlookOAuthState()
        oauthDeviceCode = nil
        oauthStatus = "Signed out and removed stored OAuth tokens for this account."
        testResult = nil
        saveSharingChange()
    }

    private func duplicateOutlookAccount() {
        guard let workspace else { return }
        let copy = Connector(
            name: "Stanford Outlook Mail",
            serviceType: StanfordOutlookMail.serviceType,
            icon: "envelope.badge.shield.half.filled",
            connectorDescription: connector.connectorDescription,
            baseURL: StanfordOutlookMail.graphBaseURL,
            authMethod: StanfordOutlookMail.authMethod
        )
        copy.workspace = workspace
        copy.skill = connector.skill
        copy.applyStanfordOutlookDefaults()
        copy.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: connector.outlookTenantDomain)
        modelContext.insert(copy)
        onDuplicate?(copy)
        saveSharingChange()
    }

    private func addCredential() {
        let key = newCredKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty, !newCredValue.isEmpty else { return }
        let saved = connector.saveCredential(key: key, value: newCredValue, allowUserInteraction: true)
        guard saved else {
            credentialSaveError = .keychainSaveFailed(key: key)
            pendingCredentialSaveContext = .newCredential
            return
        }
        credentialSaveError = nil
        pendingCredentialSaveContext = nil
        testResult = nil
        saveSharingChange()
        cancelCredentialEntry()
    }

    private func cancelCredentialEntry() {
        newCredKey = ""
        newCredValue = ""
        isAddingCredential = false
        credentialSaveError = nil
        pendingCredentialSaveContext = nil
    }

    private func saveCredentialReplacement(for key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalizedKey.isEmpty, !replacementCredentialValue.isEmpty else { return }
        let saved = connector.saveCredential(
            key: normalizedKey,
            value: replacementCredentialValue,
            allowUserInteraction: true
        )
        guard saved else {
            credentialSaveError = .keychainSaveFailed(key: normalizedKey)
            pendingCredentialSaveContext = .replacement(key: normalizedKey)
            return
        }
        credentialSaveError = nil
        pendingCredentialSaveContext = nil
        testResult = nil
        saveSharingChange()
        cancelCredentialReplacement()
    }

    private func cancelCredentialReplacement() {
        editingCredentialKey = nil
        replacementCredentialValue = ""
        credentialSaveError = nil
        pendingCredentialSaveContext = nil
    }

    private func credentialSaveErrorLabel(_ presentation: ConnectorCredentialSaveFailurePresentation) -> some View {
        Label(presentation.message, systemImage: "exclamationmark.triangle.fill")
            .font(Stanford.caption(12))
            .foregroundStyle(Stanford.poppy)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func retryCredentialSaveButton(_ presentation: ConnectorCredentialSaveFailurePresentation) -> some View {
        Button {
            retryPendingCredentialSave(for: presentation)
        } label: {
            Label(presentation.actionTitle, systemImage: presentation.actionSystemImage)
                .font(Stanford.caption(12).weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func retryPendingCredentialSave(for presentation: ConnectorCredentialSaveFailurePresentation) {
        switch pendingCredentialSaveContext {
        case .newCredential:
            addCredential()
        case .replacement(let key):
            saveCredentialReplacement(for: key)
        case nil:
            credentialSaveError = .keychainSaveFailed(key: presentation.key)
        }
    }

    private func addConfig() {
        let key = newConfigKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return }
        if let idx = connector.configKeys.firstIndex(of: key) {
            connector.configValues[idx] = newConfigValue
        } else {
            connector.configKeys.append(key)
            connector.configValues.append(newConfigValue)
        }
        connector.updatedAt = Date()
        newConfigKey = ""
        newConfigValue = ""
    }

    private func addListItem(at idx: Int) {
        let item = newListItem.trimmingCharacters(in: .whitespaces).uppercased()
        guard !item.isEmpty else { return }
        let current = connector.configValues[idx]
        let items = current.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.contains(item) else { newListItem = ""; return }
        connector.configValues[idx] = items.isEmpty ? item : current + ",\(item)"
        connector.updatedAt = Date()
        newListItem = ""
    }

    static func serviceLabel(_ type: String) -> String {
        switch type {
        case "redcap": return "REDCap"
        case "rest_api": return "REST API"
        case "github": return "GitHub"
        case "stanford_outlook_mail": return "Stanford Outlook Mail"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func authMethods(for serviceType: String) -> [String] {
        serviceType == StanfordOutlookMail.serviceType
            ? [StanfordOutlookMail.authMethod]
            : ["none", "basic", "bearer", "api_key"]
    }

    private func normalizeAuthMethodForCurrentService() {
        let methods = Self.authMethods(for: connector.serviceType)
        if !methods.contains(connector.authMethod) {
            connector.authMethod = connector.isStanfordOutlookMail ? StanfordOutlookMail.authMethod : "none"
            connector.updatedAt = Date()
        }
    }

    private func duplicateForWorkspace() {
        guard let workspace else { return }
        let copy = CapabilitySharing.duplicateForWorkspace(connector, in: workspace)
        modelContext.insert(copy)
        onDuplicate?(copy)
        saveSharingChange()
    }

    private func saveSharingChange() {
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: workspace ?? connector.workspace,
            modelContext: modelContext
        )
    }

    private func applyServiceDefaults(for type: String) {
        switch type {
        case "redcap":
            connector.icon = "cross.case"
            connector.authMethod = "api_key"
            connector.testHTTPMethod = "POST"
            if connector.credentialKeys.isEmpty {
                newCredKey = "REDCAP_TOKEN"
                isAddingCredential = true
                credentialSaveError = nil
                pendingCredentialSaveContext = nil
            }
        case "jira":
            connector.icon = "list.bullet.rectangle"
            connector.authMethod = "basic"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "JIRA_API_TOKEN"
                isAddingCredential = true
                credentialSaveError = nil
                pendingCredentialSaveContext = nil
            }
        case "github":
            connector.icon = "arrow.triangle.branch"
            connector.authMethod = "bearer"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "GITHUB_TOKEN"
                isAddingCredential = true
                credentialSaveError = nil
                pendingCredentialSaveContext = nil
            }
        case "slack":
            connector.icon = "bubble.left.and.bubble.right"
            connector.authMethod = "bearer"
            connector.testHTTPMethod = "POST"
            if connector.credentialKeys.isEmpty {
                newCredKey = "SLACK_TOKEN"
                isAddingCredential = true
                credentialSaveError = nil
                pendingCredentialSaveContext = nil
            }
        case "confluence":
            connector.icon = "doc.richtext"
            connector.authMethod = "basic"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "CONFLUENCE_TOKEN"
                isAddingCredential = true
                credentialSaveError = nil
                pendingCredentialSaveContext = nil
            }
        case "stanford_outlook_mail":
            connector.applyStanfordOutlookDefaults()
            isAddingCredential = false
            newCredKey = ""
            credentialSaveError = nil
            pendingCredentialSaveContext = nil
        default:
            break
        }
        normalizeAuthMethodForCurrentService()
        connector.updatedAt = Date()
    }
}
