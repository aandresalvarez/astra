import SwiftUI

/// Unavailable reads can mean denied vault access or an older item's ACL.
/// Replacements are saved together, with Keychain UI allowed by that gesture.
struct ConnectorCredentialReentrySection: View {
    let keys: [String]
    /// What the values let the person keep using: "account" or "skill".
    var subject = "account"
    var labels: [String: String] = [:]
    /// True once every value is saved; the fields keep what was typed otherwise.
    let save: ([String: String]) -> Bool
    @State private var values: [String: String] = [:]

    private var isComplete: Bool {
        keys.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Self.message(keyCount: keys.count, subject: subject),
                  systemImage: "exclamationmark.triangle.fill")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.poppy)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(keys, id: \.self) { key in
                HStack(spacing: 6) {
                    Text(labels[key] ?? key)
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

    static func message(keyCount: Int, subject: String) -> String {
        let description = keyCount == 1 ? "this saved secret" : "these saved secrets"
        let replacement = keyCount == 1 ? "Re-enter it" : "Re-enter them together"
        return "ASTRA can't read \(description). \(replacement) to keep using this \(subject). If macOS asks for Keychain access when saving, allow ASTRA to continue."
    }
}
