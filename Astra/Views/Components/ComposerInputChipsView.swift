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
    @State private var thumbnails: [String: NSImage] = [:]

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
            // A `stat` or an image decode per input per render would land in
            // the keystroke path (TaskMainView re-evaluates its body on every
            // character), so both run off-main, once per change of the inputs,
            // and `chip` only reads the cached results.
            .task(id: fileInputs.joined(separator: "|")) {
                let inputs = fileInputs
                let imageExtensions = Self.imageExtensions
                let (missing, thumbs) = await Task.detached(priority: .utility) { () -> (Set<String>, [String: NSImage]) in
                    var missing: Set<String> = []
                    var thumbs: [String: NSImage] = [:]
                    for path in inputs {
                        // Inputs may carry prompt-projection whitespace; the
                        // filesystem sees the trimmed path, the chip keys on the original.
                        let filePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard FileManager.default.fileExists(atPath: filePath) else { missing.insert(path); continue }
                        guard imageExtensions.contains(URL(fileURLWithPath: filePath).pathExtension.lowercased()),
                              let image = NSImage(contentsOfFile: filePath) else { continue }
                        thumbs[path] = Self.thumbnail(of: image, side: 44)
                    }
                    return (missing, thumbs)
                }.value
                // The detached decode outlives a cancelled `.task`; a slower,
                // older refresh must not overwrite the state of a newer one.
                guard !Task.isCancelled, fileInputs == inputs else { return }
                missingInputs = missing
                thumbnails = thumbs
            }
        }
    }

    private func chip(_ path: String, isMissing: Bool) -> some View {
        let name = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent

        return HStack(spacing: 6) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.poppy)
                    .frame(width: 16)
            } else if let nsImage = thumbnails[path] {
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

    /// A small pre-scaled copy so the chip never holds a full screenshot in
    /// memory or rescales it on every draw.
    private static func thumbnail(of image: NSImage, side: CGFloat) -> NSImage {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let scale = min(side / source.width, side / source.height, 1)
        let target = NSSize(width: source.width * scale, height: source.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: source), operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
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
