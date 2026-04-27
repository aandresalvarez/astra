import SwiftUI
import SwiftData

struct WorkspacePickerView: View {
    let workspaces: [Workspace]
    @Binding var selectedWorkspace: Workspace?
    let onNewWorkspace: () -> Void
    let onEditWorkspace: (Workspace) -> Void
    var onImportWorkspace: (() -> Void)?

    var body: some View {
        Menu {
            ForEach(workspaces) { ws in
                Button {
                    selectedWorkspace = ws
                } label: {
                    HStack {
                        Label(ws.name, systemImage: ws.icon)
                        if selectedWorkspace?.id == ws.id {
                            Image(systemName: "checkmark")
                        }
                        Text("\(ws.tasks.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button {
                onNewWorkspace()
            } label: {
                Label("New Workspace...", systemImage: "plus")
            }

            Button {
                onImportWorkspace?()
            } label: {
                Label("Import Workspace...", systemImage: "square.and.arrow.down")
            }

            if let ws = selectedWorkspace {
                Button {
                    onEditWorkspace(ws)
                } label: {
                    Label("Edit Workspace...", systemImage: "pencil")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedWorkspace?.icon ?? "folder")
                    .font(Stanford.ui(13))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 22, height: 22)
                    .background(Stanford.lagunita.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedWorkspace?.name ?? "No Workspace")
                        .font(Stanford.body(14))
                        .fontWeight(.medium)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    if let ws = selectedWorkspace {
                        Text(ws.displayPath)
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.coolGrey)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Stanford.fog)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
