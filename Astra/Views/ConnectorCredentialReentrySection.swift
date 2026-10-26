import SwiftUI

/// Saved values this build of ASTRA can't read. Items in ASTRA's keychain
/// trust only the build that wrote them, and changing that list takes the
/// keychain's own password, which only ASTRA holds, so no macOS prompt can
/// add a rebuilt ASTRA. The values are re-entered instead, all at once: a save
/// copies every value it keeps and can't copy one it can't read
/// (`ConnectorCredentialEditor.save`, `SkillCredentialEditor.save`).
struct ConnectorCredentialReentrySection: View {
    let keys: [String]
    /// What the values let the person keep using: "account" or "skill".
    var subject = "account"
    /// True once every value is saved; the fields keep what was typed otherwise.
    let save: ([String: String]) -> Bool
    @State private var values: [String: String] = [:]

    private var isComplete: Bool {
        keys.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(keys.count == 1
                  ? "ASTRA can't read this saved secret. An earlier build saved it; re-enter it to keep using this \(subject)."
                  : "ASTRA can't read these saved secrets. An earlier build saved them; re-enter them together to keep using this \(subject).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.poppy)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(keys, id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key)
                        .font(Stanford.ui(13, design: .monospaced))
                        .fontWeight(.medium)
                        .frame(minWidth: 100, alignment: .leading)
                    SecretEntryField("value", text: Binding(
                        get: { values[key] ?? "" },
                        set: { values[key] = $0 }
                    ), hidesValuesNotTyped: !SecretEntryPresentation.isIdentifierKey(key))
                    .font(Stanford.ui(13, design: .monospaced))
                    .onSubmit { if isComplete { submit() } }
                }
            }
            Button(keys.count == 1 ? "Save secret" : "Save secrets") { submit() }
                .disabled(!isComplete)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        if save(values.filter { keys.contains($0.key) && !$0.value.isEmpty }) { values = [:] }
    }
}
