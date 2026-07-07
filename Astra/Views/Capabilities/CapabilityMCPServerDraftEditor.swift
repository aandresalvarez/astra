import SwiftUI
import ASTRACore

struct CapabilityMCPServerDraftEditor: View {
    @Binding var draft: CapabilityMCPServerDraft
    let declaredEnvironmentKeys: Set<String>
    var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Server ID", text: $draft.serverID)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
                TextField("Display name", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Transport", selection: $draft.transport) {
                ForEach(PluginMCPServer.Transport.allCases, id: \.self) { transport in
                    Text(transport.rawValue.uppercased()).tag(transport)
                }
            }
            .pickerStyle(.segmented)

            if draft.transport == .stdio {
                TextField("Command", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
                labeledEditor("Arguments", text: $draft.argumentsText, minHeight: 64)
            } else {
                TextField("Remote URL", text: $draft.urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
            }

            HStack(alignment: .top, spacing: 10) {
                labeledEditor("Env keys", text: $draft.environmentKeysText, minHeight: 56)
                labeledEditor("Connector bindings", text: $draft.connectorBindingsText, minHeight: 56)
            }

            HStack(alignment: .top, spacing: 10) {
                labeledEditor("Allowed tools", text: $draft.allowedToolsText, minHeight: 68)
                labeledEditor("Excluded tools", text: $draft.excludedToolsText, minHeight: 68)
            }

            HStack(spacing: 12) {
                Toggle("Resources", isOn: $draft.resourcesEnabled)
                Toggle("Prompts", isOn: $draft.promptsEnabled)
                Spacer()
                Picker("Trust", selection: $draft.trustLevel) {
                    ForEach(PluginMCPServer.TrustLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .frame(width: 170)
            }
            .font(Stanford.caption(12))

            HStack(spacing: 6) {
                if declaredEnvironmentKeys.isEmpty {
                    ConfigureCardChip(title: "No declared env keys", color: Stanford.coolGrey)
                } else {
                    ForEach(Array(declaredEnvironmentKeys).sorted(), id: \.self) { key in
                        ConfigureCardChip(title: key, color: ConfigureTab.connectors.color)
                    }
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.cardinalRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledEditor(_ title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(Stanford.ui(13, design: .monospaced))
                .frame(minHeight: minHeight)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
