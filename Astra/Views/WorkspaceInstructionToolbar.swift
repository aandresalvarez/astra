import SwiftUI

/// Formatting toolbar for `WorkspaceInstructionEditorView` — one button per
/// common Markdown construct, for someone who doesn't know (or doesn't want
/// to hand-type) the syntax. Every button drives the same
/// `WorkspaceInstructionEditorController` the keyboard does, so a click and
/// typing `**` produce the identical result.
struct WorkspaceInstructionToolbar: View {
    let controller: WorkspaceInstructionEditorController

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Heading 1") { controller.applyHeading(level: 1) }
                Button("Heading 2") { controller.applyHeading(level: 2) }
                Button("Heading 3") { controller.applyHeading(level: 3) }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(WorkspaceInstructionToolbarButtonStyle())
            .fixedSize()
            .help("Heading")

            toolbarDivider

            toolbarButton("bold", help: "Bold (**text**)") { controller.toggleBold() }
            toolbarButton("italic", help: "Italic (*text*)") { controller.toggleItalic() }

            toolbarDivider

            toolbarButton("list.bullet", help: "Bulleted list") { controller.toggleBulletList() }
            toolbarButton("list.number", help: "Numbered list") { controller.toggleNumberedList() }
            toolbarButton("text.quote", help: "Quote") { controller.toggleQuote() }

            toolbarDivider

            toolbarButton("link", help: "Link") { controller.insertLink() }
            toolbarButton("chevron.left.forwardslash.chevron.right", help: "Inline code") { controller.toggleInlineCode() }
            toolbarButton("curlybraces", help: "Code block") { controller.insertCodeBlock() }

            Spacer(minLength: 0)
        }
    }

    private func toolbarButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(WorkspaceInstructionToolbarButtonStyle())
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

private struct WorkspaceInstructionToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.55 : 0.75))
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
