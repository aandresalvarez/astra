import SwiftUI
import SwiftData

struct WorkspaceDetailView: View {
    @Bindable var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirm = false
    @State private var newPath = ""
    @State private var sshConnections: [SSHConnection] = []
    @State private var editingSSH: SSHConnection?
    @State private var showSSHEditor = false
    @State private var exportMessage = ""
    @State private var pendingRemoval: PendingRemoval?
    let onDelete: () -> Void

    private let iconOptions = [
        "folder.fill", "doc.text.fill", "terminal.fill", "wrench.and.screwdriver.fill",
        "server.rack", "externaldrive.fill", "cpu.fill", "globe",
        "shield.fill", "leaf.fill", "flask.fill", "chart.bar.fill"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Workspace Settings")
                    .font(Stanford.heading(20))
                    .foregroundStyle(Stanford.black)
                Spacer()

                Menu {
                    Button("Export Config...") { exportConfig() }
                    Button("Export to Workspace Folder") { autoExportConfig() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            if !exportMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Stanford.paloAltoGreen)
                    Text(exportMessage)
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Identity
                    GroupBox("Identity") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $workspace.name)
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.body(15))

                        }
                        .padding(.vertical, 4)
                    }

                    // Instructions
                    GroupBox("General Instructions") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Describe what this workspace is about. This context is included in every task prompt.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $workspace.instructions)
                                .font(Stanford.body(14))
                                .frame(minHeight: 60, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Stanford.fog.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onChange(of: workspace.instructions) {
                                    workspace.updatedAt = Date()
                                }
                        }
                        .padding(.vertical, 4)
                    }

                    // Primary Path
                    GroupBox("Working Directory") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(workspace.primaryPath.isEmpty ? "No folder selected" : workspace.primaryPath)
                                    .font(Stanford.ui(14, design: .monospaced))
                                    .foregroundStyle(workspace.primaryPath.isEmpty ? Stanford.sandstone : Stanford.black)
                                    .lineLimit(2)
                                Spacer()
                                Button("Browse") { browsePrimaryPath() }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Additional Paths
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Extra source folders, output directories, or related repos.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)

                            if !workspace.additionalPaths.isEmpty {
                                ForEach(workspace.additionalPaths, id: \.self) { path in
                                    HStack {
                                        Image(systemName: "folder")
                                            .font(Stanford.ui(12))
                                            .foregroundStyle(Stanford.coolGrey)
                                        Text(path)
                                            .font(Stanford.ui(13, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Button {
                                            pendingRemoval = PendingRemoval(
                                                title: "Remove Folder?",
                                                message: "“\(path)” will be unlinked from this workspace. The folder itself is not deleted from disk.",
                                                confirmTitle: "Remove Folder",
                                                perform: {
                                                    workspace.additionalPaths.removeAll { $0 == path }
                                                    workspace.updatedAt = Date()
                                                }
                                            )
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(12))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Stanford.fog)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            Button("Add Folder...") { browseAdditionalPath() }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text("Additional Paths")
                            if !workspace.additionalPaths.isEmpty {
                                Text("(\(workspace.additionalPaths.count))")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // SSH Connections
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remote folders accessible via SSH for running tasks on remote servers.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)

                            if !sshConnections.isEmpty {
                                ForEach(sshConnections) { conn in
                                    HStack(spacing: 8) {
                                        Image(systemName: "network")
                                            .font(Stanford.ui(12))
                                            .foregroundStyle(Stanford.lagunita)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(conn.displayLabel)
                                                .font(Stanford.body(13))
                                                .fontWeight(.medium)
                                            Text("\(conn.sshTarget):\(conn.remotePath)")
                                                .font(Stanford.ui(12, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        // Status indicator
                                        if let result = conn.lastTestResult {
                                            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .font(Stanford.ui(13))
                                                .foregroundStyle(result ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                                        }

                                        Button {
                                            editingSSH = conn
                                            showSSHEditor = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(Stanford.ui(12))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            pendingRemoval = PendingRemoval(
                                                title: "Remove SSH Connection?",
                                                message: "“\(conn.displayLabel)” (\(conn.sshTarget):\(conn.remotePath)) will be removed from this workspace. The remote server and its files are not affected.",
                                                confirmTitle: "Remove Connection",
                                                perform: {
                                                    sshConnections.removeAll { $0.id == conn.id }
                                                    saveSSHConnections()
                                                }
                                            )
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(12))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Stanford.fog)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            Button("Add SSH Connection...") {
                                editingSSH = SSHConnection()
                                showSSHEditor = true
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text("SSH Connections")
                            if !sshConnections.isEmpty {
                                Text("(\(sshConnections.count))")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Skills
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if workspace.skills.isEmpty {
                                Text("No skills configured. Open Skills Manager to add some.")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            } else {
                                FlowLayout(spacing: 6) {
                                    ForEach(workspace.skills.sorted { $0.name < $1.name }) { skill in
                                        Label(skill.name, systemImage: skill.icon)
                                            .font(Stanford.caption(12))
                                            .foregroundStyle(Stanford.lagunita)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Stanford.lagunita.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text("Skills")
                            Spacer()
                            Text("\(workspace.skills.count)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Stats
                    GroupBox("Stats") {
                        HStack(spacing: 24) {
                            statItem("Tasks", value: "\(workspace.tasks.count)")
                            statItem("Tokens", value: Formatters.formatTokens(workspace.totalTokens))
                            statItem("Cost", value: String(format: "$%.2f", workspace.totalCost))
                        }
                        .padding(.vertical, 4)
                    }

                    // Delete
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 700)
        .alert("Delete Workspace?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("This will delete the workspace and all \(workspace.tasks.count) associated tasks. This cannot be undone.")
        }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { presented in if !presented { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button(removal.confirmTitle, role: .destructive) {
                removal.perform()
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { removal in
            Text(removal.message)
        }
        .sheet(isPresented: $showSSHEditor) {
            if let conn = editingSSH {
                SSHConnectionEditorView(
                    connection: conn,
                    onSave: { updated in
                        if let idx = sshConnections.firstIndex(where: { $0.id == updated.id }) {
                            sshConnections[idx] = updated
                        } else {
                            sshConnections.append(updated)
                        }
                        saveSSHConnections()
                        showSSHEditor = false
                    },
                    onCancel: { showSSHEditor = false }
                )
            }
        }
        .onAppear {
            sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        }
        .onChange(of: workspace.primaryPath) {
            sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        }
        .onDisappear {
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace, modelContext: modelContext)
        }
    }

    private func statItem(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Stanford.heading(16))
                .foregroundStyle(Stanford.black)
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.coolGrey)
        }
    }

    private func saveSSHConnections() {
        SSHConnectionManager.save(sshConnections, workspacePath: workspace.primaryPath)
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func browsePrimaryPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select or create the main working directory"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.primaryPath = url.path
            sshConnections = SSHConnectionManager.load(workspacePath: url.path)
            workspace.updatedAt = Date()
            WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
        }
    }

    private func browseAdditionalPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = "Select or create additional source folders"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !workspace.additionalPaths.contains(url.path) {
                    workspace.additionalPaths.append(url.path)
                }
            }
            workspace.updatedAt = Date()
            WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
        }
    }


    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspace.name.replacingOccurrences(of: " ", with: "-").lowercased())-workspace.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Export workspace config"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: modelContext, url: url)
                withAnimation { exportMessage = "Exported to \(url.lastPathComponent)" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { exportMessage = "" }
                }
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func autoExportConfig() {
        WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace, modelContext: modelContext)
        withAnimation { exportMessage = "Saved to \(workspace.displayPath)/\(WorkspaceFileLayout.workspaceConfigFileName)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { exportMessage = "" }
        }
    }
}

// MARK: - Pending Removal

/// Stages a destructive removal so the confirmation dialog can name exactly what
/// will be removed and run the removal only on an explicit second tap.
private struct PendingRemoval: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void
}

// MARK: - SSH Connection Editor

struct SSHConnectionEditorView: View {
    @State var connection: SSHConnection
    let onSave: (SSHConnection) -> Void
    let onCancel: () -> Void

    @State private var selectedTab = "form"
    @State private var isTesting = false
    @State private var testMessage = ""
    @State private var testSuccess: Bool?
    @State private var rawConfigText = ""
    @State private var configHosts: [SSHConnectionManager.SSHConfigHost] = []
    @State private var configFilePath = "~/.ssh/config"

    var isValid: Bool {
        !connection.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !connection.user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH Connection")
                    .font(Stanford.heading(18))
                    .foregroundStyle(Stanford.black)
                Spacer()
                Button("Cancel") { onCancel() }
            }
            .padding()

            Divider()

            // Mode picker
            Picker("Mode", selection: $selectedTab) {
                Text("Form").tag("form")
                Text("Text Edit").tag("text")
                Text("Import from Config").tag("import")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case "form":
                formTab
            case "text":
                textEditTab
            case "import":
                importTab
            default:
                EmptyView()
            }

            Divider()

            // Test + Save footer
            HStack {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(Stanford.ui(13))
                        }
                        Text(isTesting ? "Testing..." : "Test")
                    }
                }
                .disabled(!isValid || isTesting)

                if let success = testSuccess {
                    HStack(spacing: 4) {
                        Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(success ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                        Text(success ? "OK" : "Failed")
                            .font(Stanford.caption(12))
                            .foregroundStyle(success ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                    }
                }

                if !testMessage.isEmpty {
                    Text(testMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Save") {
                    onSave(connection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            rawConfigText = connectionToConfigText(connection)
        }
    }

    // MARK: - Form Tab

    private var formTab: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $connection.name, prompt: Text("e.g., dev-server"))
                TextField("Host", text: $connection.host, prompt: Text("hostname or IP"))
                TextField("User", text: $connection.user, prompt: Text("SSH username"))
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $connection.port, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Remote Path") {
                TextField("Path", text: $connection.remotePath, prompt: Text("e.g., ~/projects/myapp"))
            }

            Section("Authentication") {
                HStack {
                    TextField("Key File", text: $connection.keyPath, prompt: Text("Default (~/.ssh/id_rsa)"))
                    Button("Browse") { browseKeyFile() }
                }
                Text("Leave empty to use default SSH key.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            if !connection.configAlias.isEmpty {
                Section("SSH Config") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Stanford.paloAltoGreen)
                        Text("Uses SSH config alias: **\(connection.configAlias)**")
                            .font(Stanford.body(14))
                        Spacer()
                    }
                    Text("Connection will use your ~/.ssh/config settings including ProxyCommand.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Text Edit Tab

    private var textEditTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste or edit SSH config block directly:")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            TextEditor(text: $rawConfigText)
                .font(Stanford.ui(14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Stanford.fog.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)

            HStack {
                Button("Apply") {
                    applyConfigText()
                }
                .disabled(rawConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isValid {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Stanford.paloAltoGreen)
                        Text("Parsed: \(connection.sshTarget)")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Import Tab

    private var importTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Config file", text: $configFilePath)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(14, design: .monospaced))
                Button("Browse") { browseConfigFile() }
                Button("Load") { loadConfigFile() }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if configHosts.isEmpty {
                VStack {
                    Spacer()
                    Text("Click Load to read hosts from your SSH config file.")
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                List(configHosts) { host in
                    Button {
                        selectConfigHost(host)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(Stanford.body(14))
                                    .fontWeight(.medium)
                                    .foregroundStyle(Stanford.black)
                                Text("\(host.user.isEmpty ? "?" : host.user)@\(host.hostname)")
                                    .font(Stanford.ui(12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !host.identityFile.isEmpty {
                                Image(systemName: "key")
                                    .font(Stanford.ui(11))
                                    .foregroundStyle(Stanford.coolGrey)
                            }
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func testConnection() {
        isTesting = true
        testMessage = ""
        testSuccess = nil

        let conn = connection
        Task {
            let result = await SSHConnectionManager.test(conn)
            await MainActor.run {
                isTesting = false
                testSuccess = result.success
                testMessage = result.message
                connection.lastTestedAt = Date()
                connection.lastTestResult = result.success
            }
        }
    }

    private func browseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Select SSH private key"
        if panel.runModal() == .OK, let url = panel.url {
            connection.keyPath = url.path
        }
    }

    private func browseConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Select SSH config file"
        if panel.runModal() == .OK, let url = panel.url {
            configFilePath = url.path
            loadConfigFile()
        }
    }

    private func loadConfigFile() {
        configHosts = SSHConnectionManager.parseSSHConfig(at: configFilePath)
    }

    private func selectConfigHost(_ host: SSHConnectionManager.SSHConfigHost) {
        connection = SSHConnectionManager.connectionFromConfig(host, remotePath: connection.remotePath)
        rawConfigText = connectionToConfigText(connection)
        selectedTab = "form"
    }

    private func connectionToConfigText(_ conn: SSHConnection) -> String {
        var lines: [String] = []
        lines.append("Host \(conn.name.isEmpty ? "my-server" : conn.name)")
        if !conn.host.isEmpty { lines.append("  Hostname \(conn.host)") }
        if !conn.user.isEmpty { lines.append("  User \(conn.user)") }
        if conn.port != 22 { lines.append("  Port \(conn.port)") }
        if !conn.keyPath.isEmpty { lines.append("  IdentityFile \(conn.keyPath)") }
        return lines.joined(separator: "\n")
    }

    private func applyConfigText() {
        let hosts = SSHConnectionManager.parseSSHConfig(from: rawConfigText)
        guard let first = hosts.first else { return }
        let remotePath = connection.remotePath
        connection = SSHConnectionManager.connectionFromConfig(first, remotePath: remotePath)
    }
}
