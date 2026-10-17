import SwiftUI
import ASTRACore
import ASTRAModels

/// A presentation derived from durable inputs and the existing file index.
/// Input paths stay listed even when a missing file is absent from that index.
struct TaskFilesPopoverPresentation {
    let inputPaths: [String]
    let otherFiles: [TaskFileItem]
    var fileCount: Int { inputPaths.count + otherFiles.count }

    init(items: [TaskFileItem], inputs: [String]) {
        inputPaths = ComposerAttachments.paths(in: inputs)
        let paths = Set(inputPaths.map(TaskFileIndex.normalizedPath))
        otherFiles = items.filter { !paths.contains(TaskFileIndex.normalizedPath($0.path)) }
    }
}

struct TaskFilesPopoverView: View {
    let task: AgentTask
    let items: [TaskFileItem]
    let canOpenTextFiles: Bool
    let formatSize: (Int64) -> String
    let onOpenFile: (TaskFileItem) -> Void
    let onOpenTextFiles: () -> Void
    let onOpenFolder: (() -> Void)?

    var body: some View {
        let presentation = TaskFilesPopoverPresentation(items: items, inputs: task.inputs)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Task Files")
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Spacer()
                if presentation.fileCount > 0 {
                    Text("\(presentation.fileCount)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            if presentation.fileCount == 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No files yet")
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.black)
                    Text("Generated and attached files will appear here.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TaskInputFilesView(task: task) { path in
                            let path = TaskFileIndex.normalizedPath(path)
                            onOpenFile(TaskFileItem(path: path, source: "input",
                                destination: TaskGeneratedFiles.shelfDestination(for: path)))
                        }
                        if !presentation.inputPaths.isEmpty && !presentation.otherFiles.isEmpty {
                            Divider()
                        }
                        ForEach(presentation.otherFiles) { item in
                            fileRow(item)
                            if item.id != presentation.otherFiles.last?.id {
                                Divider().padding(.leading, 39)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider()
            HStack(spacing: 8) {
                Button(action: onOpenTextFiles) {
                    Label("Open in Files", systemImage: "square.split.2x1")
                        .font(Stanford.caption(12).weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canOpenTextFiles ? Stanford.lagunita : .secondary)
                .disabled(!canOpenTextFiles)
                .help("Open all text files in the Files shelf")
                Spacer()
                if let onOpenFolder {
                    Button(action: onOpenFolder) {
                        Image(systemName: "folder")
                            .font(Stanford.ui(12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.lagunita)
                    .help("Open task folder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Stanford.panelBackground)
    }

    private func fileRow(_ item: TaskFileItem) -> some View {
        Button { onOpenFile(item) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.destination?.systemImage ?? Formatters.fileIcon(for: item.path))
                    .font(Stanford.ui(13))
                    .foregroundStyle(item.destination == nil ? Stanford.coolGrey : Stanford.lagunita)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    Text(item.path)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.source)
                        .font(Stanford.caption(10).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                    let size = formatSize(item.size)
                    if !size.isEmpty {
                        Text(size).font(Stanford.caption(10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.destination?.title ?? "Open in default app")
    }
}
