import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Persisted attachments belong to the chat's Files surface, not the draft
/// of its next message. Missing files stay visible here so they can be removed
/// from future context without deleting their original conversation record.
struct TaskInputFilesView: View {
    let task: AgentTask
    let onOpen: (TaskFileItem) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var metadata: TaskInputFileMetadata?

    private var fileInputs: [String] { ComposerAttachments.paths(in: task.inputs) }

    var body: some View {
        if !fileInputs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Attached to this chat")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ForEach(fileInputs, id: \.self) { path in
                    inputRow(path)
                }
            }
            .task(id: fileInputs) {
                let inputs = fileInputs
                let snapshot = await Task.detached(priority: .utility) {
                    TaskInputFileMetadata.load(paths: inputs)
                }.value
                guard !Task.isCancelled, fileInputs == inputs else { return }
                metadata = snapshot
            }
        }
    }

    private func inputRow(_ path: String) -> some View {
        let name = ComposerAttachments.displayName(for: path)
        let isMissing = metadata?.missing.contains(path) == true
        let item = metadata?.items[path]
        return HStack(spacing: 8) {
            Button { if let item { onOpen(item) } } label: {
                HStack(spacing: 9) {
                    Image(systemName: isMissing ? "exclamationmark.triangle.fill" : (item?.isDirectory == true ? "folder" : Formatters.fileIcon(for: path)))
                        .font(Stanford.ui(13))
                        .foregroundStyle(isMissing ? Stanford.poppy : Stanford.lagunita)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(Stanford.body(13).weight(.medium))
                            .foregroundStyle(Stanford.black)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(isMissing ? "Missing file" : path)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item == nil)
            .accessibilityLabel(isMissing ? "Missing chat attachment \(name)" : "Open chat attachment \(name)")
            Button { remove(path, wasMissing: isMissing) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.coolGrey.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Remove this file from future chat context")
            .accessibilityLabel("Remove \(name) from chat context")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(isMissing ? "\(path)\n\nMissing — macOS may have cleaned it out of the temporary folder." : path)
    }

    private func remove(_ path: String, wasMissing: Bool) {
        task.inputs.removeAll { $0 == path }
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace, modelContext: modelContext, taskID: task.id,
            auditFields: ["operation": "task_input_removed", "was_missing": String(wasMissing)]
        )
    }
}
