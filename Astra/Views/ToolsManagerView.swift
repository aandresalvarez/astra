import SwiftUI
import SwiftData

struct ToolsManagerView: View {
    var workspace: Workspace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTool: LocalTool?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tools")
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
                Spacer()
                Button { createTool() } label: {
                    Label("New Tool", systemImage: "plus")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                // List
                List(selection: $selectedTool) {
                    ForEach(workspace.localTools.sorted(by: { $0.name < $1.name })) { tool in
                        toolRow(tool)
                            .tag(tool)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                .background(Stanford.fog)

                Divider()

                // Editor
                if let tool = selectedTool {
                    LocalToolEditorView(tool: tool, workspace: workspace, onDelete: {
                        deleteTool(tool)
                    }, onDuplicate: { copy in
                        selectedTool = copy
                    })
                } else {
                    ContentUnavailableView(
                        "Select a Tool",
                        systemImage: "terminal",
                        description: Text("Select a tool to edit or click + to create one.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 600, height: 420)
        .onAppear {
            if selectedTool == nil, let first = workspace.localTools.first {
                selectedTool = first
            }
        }
    }

    private func toolRow(_ tool: LocalTool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: LocalTool.iconForType(tool.toolType))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name.isEmpty ? "Untitled" : tool.name)
                    .font(Stanford.ui(14, weight: .semibold))
                Text(tool.displayCommand)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(tool.displayCommand)
    }

    private func createTool() {
        let tool = LocalTool(name: "New Tool")
        tool.workspace = workspace
        modelContext.insert(tool)
        selectedTool = tool
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func deleteTool(_ tool: LocalTool) {
        if selectedTool?.id == tool.id {
            selectedTool = nil
        }
        workspace.enabledGlobalToolIDs.removeAll { $0 == tool.id.uuidString }
        modelContext.delete(tool)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

// MARK: - Local Tool Editor

struct LocalToolEditorView: View {
    @Bindable var tool: LocalTool
    var workspace: Workspace? = nil
    let onDelete: () -> Void
    var onDuplicate: ((LocalTool) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isNameFocused: Bool
    @State private var pendingToolDeletion: PendingToolDeletion?

    private let typeOptions = [
        ("cli", "CLI Command", "terminal"),
        ("script", "Script File", "doc.text.fill"),
        ("mcp", "MCP Tool", "puzzlepiece.extension"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Identity
                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: $tool.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                        TextField("Description", text: $tool.toolDescription)
                            .textFieldStyle(.roundedBorder)

                        // Type picker
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Type")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(typeOptions, id: \.0) { type, label, icon in
                                    Button {
                                        tool.toolType = type
                                        tool.icon = icon
                                        tool.updatedAt = Date()
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: icon)
                                                .font(Stanford.ui(13))
                                            Text(label)
                                                .font(Stanford.body(14))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(tool.toolType == type ? Stanford.lagunita.opacity(0.15) : Stanford.fog)
                                        .foregroundStyle(tool.toolType == type ? Stanford.lagunita : Stanford.coolGrey)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(tool.toolType == type ? Stanford.lagunita : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Command
                GroupBox("Command") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(commandHint)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)

                        TextField(commandPlaceholder, text: $tool.command)
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(14, design: .monospaced))

                        if tool.toolType != "mcp" {
                            TextField("Default arguments (optional)", text: $tool.arguments)
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.ui(14, design: .monospaced))
                        }

                        // Browse button for scripts
                        if tool.toolType == "script" {
                            Button {
                                browseScript()
                            } label: {
                                Label("Browse...", systemImage: "folder")
                                    .font(Stanford.body(14))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Preview
                if !tool.command.isEmpty {
                    GroupBox("Preview") {
                        HStack {
                            Image(systemName: "terminal")
                                .font(Stanford.ui(13))
                                .foregroundStyle(Stanford.coolGrey)
                            Text(tool.displayCommand)
                                .font(Stanford.ui(13, design: .monospaced))
                                .foregroundStyle(Stanford.black)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Sharing
                if workspace != nil || tool.isGlobal {
                    GroupBox("Sharing") {
                        if tool.isGlobal {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: Binding(
                                    get: {
                                        guard let workspace else { return false }
                                        return workspace.enabledGlobalToolIDs.contains(tool.id.uuidString)
                                    },
                                    set: { enabled in
                                        guard let workspace else { return }
                                        if enabled {
                                            CapabilitySharing.enableShared(tool, in: workspace)
                                        } else {
                                            CapabilitySharing.disableShared(tool, in: workspace)
                                        }
                                        saveSharingChange()
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enabled in this workspace")
                                            .font(Stanford.body(14))
                                        Text("The shared tool stays installed for other workspaces.")
                                            .font(Stanford.caption(12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(workspace == nil)

                                Divider()

                                HStack {
                                    Spacer()
                                    Button {
                                        duplicateForWorkspace()
                                    } label: {
                                        Label("Duplicate for this workspace", systemImage: "doc.on.doc")
                                            .font(Stanford.body(13))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(workspace == nil)
                                }
                            }
                        } else {
                            Toggle(isOn: Binding(
                                get: { tool.isGlobal },
                                set: { newValue in
                                    if newValue {
                                        CapabilitySharing.promoteToShared(tool, in: workspace)
                                    }
                                    saveSharingChange()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Shared across all workspaces")
                                        .font(Stanford.body(14))
                                    Text("Enable this tool in any workspace's plug-ins panel")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        let name = tool.name.isEmpty ? "Untitled" : tool.name
                        pendingToolDeletion = PendingToolDeletion(name: name, perform: onDelete)
                    } label: {
                        Label("Delete Tool", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Delete Tool",
            isPresented: Binding(
                get: { pendingToolDeletion != nil },
                set: { presented in if !presented { pendingToolDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingToolDeletion
        ) { deletion in
            Button("Delete", role: .destructive) {
                deletion.perform()
                pendingToolDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingToolDeletion = nil
            }
        } message: { deletion in
            Text("Delete \u{201C}\(deletion.name)\u{201D}? This can't be undone.")
        }
        .onAppear { if tool.name == "New Tool" { isNameFocused = true } }
        .onDisappear {
            tool.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace ?? tool.workspace, modelContext: modelContext)
        }
    }

    private var commandHint: String {
        switch tool.toolType {
        case "script": return "Path to a script file (.sh, .py, .rb, .js)"
        case "mcp": return "MCP tool name (e.g. mcp__server__tool_name)"
        case "cli": return "CLI command to execute (e.g. jq, curl, docker)"
        default: return "Command or path"
        }
    }

    private var commandPlaceholder: String {
        switch tool.toolType {
        case "script": return "/path/to/script.sh"
        case "mcp": return "mcp__server__tool"
        case "cli": return "command"
        default: return "command"
        }
    }

    private func browseScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a script file"
        if panel.runModal() == .OK, let url = panel.url {
            tool.command = url.path
            tool.updatedAt = Date()
        }
    }

    private func duplicateForWorkspace() {
        guard let workspace else { return }
        let copy = CapabilitySharing.duplicateForWorkspace(tool, in: workspace)
        modelContext.insert(copy)
        onDuplicate?(copy)
        saveSharingChange()
    }

    private func saveSharingChange() {
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: workspace ?? tool.workspace,
            modelContext: modelContext
        )
        AppLogger.audit(.localToolUpdated, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "is_global": String(tool.isGlobal)
        ])
    }
}

private struct PendingToolDeletion: Identifiable {
    let id = UUID()
    let name: String
    let perform: () -> Void
}
