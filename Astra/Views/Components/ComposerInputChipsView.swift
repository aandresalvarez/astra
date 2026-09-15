import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Chips for the file inputs a task already carries from earlier turns, shown
/// above the composer of an existing task.
///
/// Those inputs used to be invisible in the composer and impossible to drop,
/// so a pasted attachment that macOS had purged left the task un-launchable
/// with no way out. A chip whose file no longer exists is drawn in the
/// warning colour and says so; its remove button edits `task.inputs` and
/// saves, which also refreshes the header file list through the existing
/// inputs signature. Prose inputs (chained-task output, context snippets) are
/// not paths and are not shown.
struct ComposerInputChipsView: View {
    let task: AgentTask

    @Environment(\.modelContext) private var modelContext
    @State private var missingInputs: Set<String> = []

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]

    private var fileInputs: [String] {
        task.inputs.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }
    }

    var body: some View {
        if !fileInputs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(fileInputs, id: \.self) { path in
                        chip(path, isMissing: missingInputs.contains(path))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }
            // A `stat` per input per render would land in the keystroke path
            // (TaskMainView re-evaluates its body on every character), so the
            // existence check runs off-main and only when the inputs change.
            .task(id: fileInputs.joined(separator: "|")) {
                let inputs = fileInputs
                let missing = await Task.detached(priority: .utility) {
                    Set(inputs.filter { !FileManager.default.fileExists(atPath: $0) })
                }.value
                missingInputs = missing
            }
        }
    }

    private func chip(_ path: String, isMissing: Bool) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let isImage = Self.imageExtensions.contains(ext)

        return HStack(spacing: 6) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.poppy)
                    .frame(width: 16)
            } else if isImage, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: Formatters.fileIcon(for: path))
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 16)
            }
            Text(name)
                .font(Stanford.caption(12))
                .foregroundStyle(isMissing ? Stanford.coolGrey : Stanford.black)
                .strikethrough(isMissing)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button {
                remove(path, wasMissing: isMissing)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.coolGrey.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help(isMissing ? "This file no longer exists. Remove it from the task." : "Remove this input from the task")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(isMissing ? Stanford.poppy.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(isMissing ? "\(path)\n\nMissing — macOS may have cleaned it out of the temporary folder." : path)
        .accessibilityLabel(isMissing ? "Missing task input \(name)" : "Task input \(name)")
    }

    private func remove(_ path: String, wasMissing: Bool) {
        task.inputs.removeAll { $0 == path }
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: [
                "operation": "task_input_removed",
                "was_missing": String(wasMissing)
            ]
        )
    }
}
