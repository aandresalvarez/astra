import SwiftUI
import SwiftData

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
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
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
            Image(systemName: connector.icon)
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name.isEmpty ? "Untitled" : connector.name)
                    .font(Stanford.body(15))
                Text(connector.displaySummary)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
    @State private var newListItem = ""
    @State private var testResult: (Bool, String)?
    @State private var isTesting = false
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
                                ForEach(["jira", "github", "slack", "database", "rest_api", "confluence", "redcap", "custom"], id: \.self) { t in
                                    Text(Self.serviceLabel(t)).tag(t)
                                }
                            }
                            .frame(width: 200)

                            Picker("Auth", selection: $connector.authMethod) {
                                ForEach(["none", "basic", "bearer", "api_key"], id: \.self) { a in
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
                            isTesting = true
                            testResult = nil
                            Task {
                                let result = await connector.testConnection()
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
                            connector.baseURL.isEmpty ||
                            (connector.authMethod != "none" && connector.credentialKeys.isEmpty) ||
                            isTesting
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

                // Configuration (non-secret)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Non-secret parameters visible in the UI. Used for scoping (projects, repos, channels).")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)

                        ForEach(Array(connector.configKeys.enumerated()), id: \.offset) { idx, key in
                            if idx < connector.configValues.count {
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
                                                        guard idx < connector.configValues.count else { return }
                                                        let updated = items.filter { $0 != item }.joined(separator: ",")
                                                        connector.configValues[idx] = updated
                                                        connector.updatedAt = Date()
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
                                            guard idx < connector.configKeys.count,
                                                  idx < connector.configValues.count else { return }
                                            connector.configKeys.remove(at: idx)
                                            connector.configValues.remove(at: idx)
                                            connector.updatedAt = Date()
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(11))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(8)
                                .background(Stanford.fog)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                            Button("Add") { addConfig() }
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

                        if !connector.credentialKeys.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(connector.credentialKeys, id: \.self) { key in
                                    let idx = connector.credentialKeys.firstIndex(of: key) ?? 0
                                    HStack(spacing: 8) {
                                        Text(key)
                                            .font(Stanford.ui(13, design: .monospaced))
                                            .fontWeight(.medium)
                                            .frame(minWidth: 100, alignment: .leading)

                                        let inKeychain = KeychainService.exists(key: key, connectorID: connector.id)

                                        if showSecrets {
                                            let value = KeychainService.load(key: key, connectorID: connector.id)
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
                                                Image(systemName: inKeychain ? "checkmark.shield.fill" : "exclamationmark.triangle")
                                                    .font(Stanford.ui(10))
                                                    .foregroundStyle(inKeychain ? Stanford.paloAltoGreen : Stanford.poppy)
                                                    .help(inKeychain ? "Stored in Keychain" : "Not yet in Keychain — re-enter value")
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
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button {
                                                connector.removeCredential(at: idx)
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(Stanford.ui(12))
                                                    .foregroundStyle(Stanford.coolGrey)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Stanford.fog)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                                Button("Add") { addCredential() }
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
                            } label: {
                                Label("Add Secret", systemImage: "plus.circle")
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Stanford.sandstone.opacity(0.4), lineWidth: 1)
                        )
                }

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Connector", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .onAppear { if connector.name == "New Connector" { isNameFocused = true } }
        .onChange(of: connector.serviceType) { _, newType in
            applyServiceDefaults(for: newType)
        }
        .onDisappear {
            connector.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(
                workspace: workspace ?? connector.workspace,
                modelContext: modelContext
            )
        }
    }

    private func addCredential() {
        let key = newCredKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty, !newCredValue.isEmpty else { return }
        connector.saveCredential(key: key, value: newCredValue)
        testResult = nil
        cancelCredentialEntry()
    }

    private func cancelCredentialEntry() {
        newCredKey = ""
        newCredValue = ""
        isAddingCredential = false
    }

    private func saveCredentialReplacement(for key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalizedKey.isEmpty, !replacementCredentialValue.isEmpty else { return }
        connector.saveCredential(key: normalizedKey, value: replacementCredentialValue)
        testResult = nil
        cancelCredentialReplacement()
    }

    private func cancelCredentialReplacement() {
        editingCredentialKey = nil
        replacementCredentialValue = ""
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

    private static func serviceLabel(_ type: String) -> String {
        switch type {
        case "redcap": return "REDCap"
        case "rest_api": return "REST API"
        case "github": return "GitHub"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
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
            }
        case "jira":
            connector.icon = "list.bullet.rectangle"
            connector.authMethod = "basic"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "JIRA_TOKEN"
                isAddingCredential = true
            }
        case "github":
            connector.icon = "arrow.triangle.branch"
            connector.authMethod = "bearer"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "GITHUB_TOKEN"
                isAddingCredential = true
            }
        case "slack":
            connector.icon = "bubble.left.and.bubble.right"
            connector.authMethod = "bearer"
            connector.testHTTPMethod = "POST"
            if connector.credentialKeys.isEmpty {
                newCredKey = "SLACK_TOKEN"
                isAddingCredential = true
            }
        case "confluence":
            connector.icon = "doc.richtext"
            connector.authMethod = "basic"
            connector.testHTTPMethod = "GET"
            if connector.credentialKeys.isEmpty {
                newCredKey = "CONFLUENCE_TOKEN"
                isAddingCredential = true
            }
        default:
            break
        }
        connector.updatedAt = Date()
    }
}
