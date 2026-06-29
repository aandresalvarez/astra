import SwiftUI

struct MCPInstallTargetPasteSheet: View {
    @Binding var targetText: String
    let onCancel: () -> Void
    let onReview: () -> Void

    private var canReview: Bool {
        guard !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return MCPInstallChatCommand.installResult(input: "/mcp \(targetText)") != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 34, height: 34)
                    .background(Stanford.lagunita.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(CapabilityCreationPresentation.pasteSheetTitle)
                        .font(Stanford.heading(18))
                    Text(CapabilityCreationPresentation.pasteSheetSubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Target")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextEditor(text: $targetText)
                    .font(Stanford.ui(12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .frame(minHeight: CGFloat(CapabilityCreationPresentation.mcpPasteTextEditorMinimumHeight))

                Text("Examples: npx -y @vendor/server@1.2.3, npm:@vendor/server@1.2.3, uvx mcp-server==1.2.3, docker run vendor/server:1.2.3, https://example.com/mcp")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onReview()
                } label: {
                    Label("Review", systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .disabled(!canReview)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: CGFloat(CapabilityCreationPresentation.mcpPasteSheetWidth))
        .frame(minHeight: CGFloat(CapabilityCreationPresentation.mcpPasteSheetMinimumHeight))
    }
}
