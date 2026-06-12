import SwiftUI

/// Menu row label for a model choice: the provider-reported display name as
/// the title and, when it differs, the raw `--model` ID underneath so the
/// exact string stays discoverable (it is what tasks launch with and what
/// the custom-model text fields accept).
struct ModelMenuItemLabel: View {
    let model: String
    let displayName: String
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                if displayName != model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}
