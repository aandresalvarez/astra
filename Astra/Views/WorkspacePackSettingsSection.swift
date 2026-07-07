import SwiftUI
import SwiftData
import ASTRAModels
import ASTRAPersistence

struct WorkspacePackSettingsSection: View {
    @Bindable var workspace: Workspace
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot = AstraPackCatalogSnapshot(entries: [], diagnostics: [])
    @State private var hasLoadedPacks = false

    private var presentation: WorkspacePackSettingsPresentation {
        WorkspacePackSettingsPresentation.make(
            snapshot: snapshot,
            enabledPackIDs: workspace.enabledPackIDs
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if presentation.rows.isEmpty {
                    Text("No packs available.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().opacity(0.4)
                            }
                            WorkspacePackSettingsRow(
                                row: row,
                                isEnabled: Binding(
                                    get: { isPackEnabled(row.id) },
                                    set: { setPack(row.id, enabled: $0) }
                                )
                            )
                            .padding(.vertical, 8)
                        }
                    }
                }

                if !presentation.diagnostics.isEmpty {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(presentation.diagnostics) { diagnostic in
                            WorkspacePackDiagnosticRow(diagnostic: diagnostic)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Packs")
                if hasLoadedPacks {
                    Text("\(presentation.enabledCount)/\(presentation.availableCount)")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reloadPacks()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload packs")
            }
        }
        .task {
            if !hasLoadedPacks {
                reloadPacks()
            }
        }
    }

    private func isPackEnabled(_ packID: String) -> Bool {
        Set(WorkspacePackSelectionPolicy.normalized(workspace.enabledPackIDs)).contains(packID)
    }

    private func setPack(_ packID: String, enabled: Bool) {
        let nextPackIDs = WorkspacePackSelectionPolicy.enabledPackIDs(
            current: workspace.enabledPackIDs,
            setting: packID,
            isEnabled: enabled
        )
        guard workspace.enabledPackIDs != nextPackIDs else { return }
        workspace.enabledPackIDs = nextPackIDs
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func reloadPacks() {
        snapshot = AstraPackCatalog().load()
        hasLoadedPacks = true
    }
}

private struct WorkspacePackSettingsRow: View {
    var row: WorkspacePackSettingsPresentation.Row
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.iconSystemName)
                    .font(Stanford.ui(15))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text(metadataText)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                Toggle("Enable \(row.name)", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                WorkspacePackFactRow(label: "Shelves", value: row.shelfSummary)
                WorkspacePackFactRow(label: "Templates", value: row.templateSummary)
                WorkspacePackFactRow(label: "Capabilities", value: row.capabilitySummary)
                WorkspacePackFactRow(label: "Policies", value: row.policySummary)
            }
            .padding(.leading, 30)
        }
    }

    private var metadataText: String {
        [row.sourceLabel, row.versionLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private var iconColor: Color {
        row.sourceLabel == "Missing" ? Stanford.cardinalRed : Stanford.coolGrey
    }
}

private struct WorkspacePackFactRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct WorkspacePackDiagnosticRow: View {
    var diagnostic: WorkspacePackSettingsPresentation.Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.cardinalRed)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(diagnostic.detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
